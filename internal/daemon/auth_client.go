package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"cs-storage/internal/auth"
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
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.ServerURL, "/")+"/auth", bytes.NewReader(b))
	if err != nil {
		return out, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := c.Client
	if client == nil {
		client = &http.Client{Timeout: 10 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return out, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return out, fmt.Errorf("auth server returned %s", resp.Status)
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return out, err
	}
	if out.Value == "" {
		return out, fmt.Errorf("auth server returned empty token")
	}
	return out, nil
}
