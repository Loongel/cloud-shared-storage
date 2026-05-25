package daemon

import (
	"bytes"
	"context"
	"cs-storage/internal/volume"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

type RcloneRC struct {
	Addr     string
	User     string
	Password string
	Client   *http.Client
}

func (r RcloneRC) Forget(ctx context.Context, dir string) error {
	if r.Addr == "" {
		return nil
	}
	payload := map[string]string{}
	if dir != "" && dir != "/" {
		payload["dir"] = dir
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, r.Addr+"/vfs/forget", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if r.User != "" || r.Password != "" {
		req.SetBasicAuth(r.User, r.Password)
	}
	client := r.Client
	if client == nil {
		client = &http.Client{Timeout: 5 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("rclone vfs/forget returned %s", resp.Status)
	}
	return nil
}

func (s *Server) forgetRcloneVFS(ctx context.Context, meta volume.Metadata) error {
	if !meta.Options.NeedsRealtimeRclone() {
		return nil
	}
	return (RcloneRC{
		Addr:     s.cfg.RcloneRCAddr,
		User:     s.cfg.RcloneRCUser,
		Password: s.cfg.RcloneRCPassword,
	}).Forget(ctx, "/")
}
