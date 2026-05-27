package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"cs-storage/internal/auth"
)

const (
	defaultAuthClientTimeout = 30 * time.Second
	defaultAuthRetryAttempts = 5
	defaultAuthRetryDelay    = 500 * time.Millisecond
)

type AuthClient struct {
	ServerURL string
	NodeID    string
	Secret    string
	Namespace string
	Client    *http.Client
}

type Token struct {
	Value    string `json:"token"`
	Expires  int64  `json:"expires"`
	Sandbox  string `json:"sandbox"`
	Endpoint string `json:"endpoint"`
}

func (c AuthClient) Token(ctx context.Context) (Token, error) {
	var out Token
	if c.ServerURL == "" || c.NodeID == "" || c.Secret == "" {
		return out, fmt.Errorf("server url, node id, and secret are required")
	}
	ts := time.Now().Unix()
	payload := map[string]any{
		"node_id":   c.NodeID,
		"timestamp": ts,
		"signature": auth.SignNodeAuth(c.Secret, c.NodeID, ts),
	}
	if c.Namespace != "" {
		payload["namespace"] = c.Namespace
	}
	b, err := json.Marshal(payload)
	if err != nil {
		return out, err
	}
	client := c.Client
	if client == nil {
		client = &http.Client{Timeout: defaultAuthClientTimeout}
	}
	var lastErr error
	for attempt := 1; attempt <= defaultAuthRetryAttempts; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.ServerURL, "/")+"/auth", bytes.NewReader(b))
		if err != nil {
			return out, err
		}
		req.Header.Set("Content-Type", "application/json")
		resp, err := client.Do(req)
		if err != nil {
			if ctx.Err() != nil {
				return out, ctx.Err()
			}
			lastErr = err
		} else {
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				defer resp.Body.Close()
				if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
					return out, err
				}
				if out.Value == "" {
					return out, fmt.Errorf("auth server returned empty token")
				}
				return out, nil
			}
			lastErr = fmt.Errorf("auth server returned %s", resp.Status)
			_, _ = io.Copy(io.Discard, resp.Body)
			_ = resp.Body.Close()
			if !retriableAuthStatus(resp.StatusCode) {
				return out, lastErr
			}
		}
		if attempt == defaultAuthRetryAttempts {
			break
		}
		if err := sleepWithContext(ctx, time.Duration(attempt)*defaultAuthRetryDelay); err != nil {
			return out, err
		}
	}
	if lastErr == nil {
		lastErr = fmt.Errorf("auth request failed")
	}
	return out, lastErr
}

func retriableAuthStatus(status int) bool {
	return status == http.StatusTooManyRequests || status == http.StatusBadGateway || status == http.StatusServiceUnavailable || status == http.StatusGatewayTimeout || status >= 500
}

func sleepWithContext(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
