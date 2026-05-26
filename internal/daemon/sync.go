package daemon

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"cs-storage/internal/volume"
)

type PeriodicSyncManager struct {
	mu     sync.Mutex
	cancel map[string]context.CancelFunc
}

func NewPeriodicSyncManager() *PeriodicSyncManager {
	return &PeriodicSyncManager{cancel: map[string]context.CancelFunc{}}
}

func (m *PeriodicSyncManager) Start(key string, interval time.Duration, logPath string, fn func(context.Context, io.Writer) error) error {
	if key == "" {
		return fmt.Errorf("periodic sync key is required")
	}
	if interval < time.Second {
		interval = time.Second
	}
	if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err != nil {
		return err
	}
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.mu.Lock()
	if _, ok := m.cancel[key]; ok {
		m.mu.Unlock()
		_ = logFile.Close()
		cancel()
		return nil
	}
	m.cancel[key] = cancel
	m.mu.Unlock()
	go m.loop(key, ctx, logFile, interval, fn)
	return nil
}

func (m *PeriodicSyncManager) loop(key string, ctx context.Context, logFile *os.File, interval time.Duration, fn func(context.Context, io.Writer) error) {
	defer logFile.Close()
	defer func() {
		m.mu.Lock()
		delete(m.cancel, key)
		m.mu.Unlock()
	}()
	for {
		if err := fn(ctx, logFile); err != nil && ctx.Err() == nil {
			fmt.Fprintf(logFile, "%s sync failed: %v\n", time.Now().Format(time.RFC3339), err)
		}
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			return
		case <-timer.C:
		}
	}
}

func (m *PeriodicSyncManager) Stop(key string) {
	m.mu.Lock()
	cancel := m.cancel[key]
	delete(m.cancel, key)
	m.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (s *Server) ensurePeriodicSync(_ context.Context, meta volume.Metadata) error {
	if !PlanPipeline(meta.Options).PeriodicSync || s.cfg.RcloneSyncInterval <= 0 {
		return nil
	}
	if s.cfg.ServerURL == "" || s.cfg.NodeID == "" || s.cfg.NodeSecret == "" {
		return fmt.Errorf("periodic rclone sync requires CS_SERVER_URL, CS_NODE_ID, and CS_NODE_SECRET_KEY")
	}
	if s.syncs == nil {
		s.syncs = NewPeriodicSyncManager()
	}
	layout := s.layout(meta.Name)
	return s.syncs.Start("rclone-sync:"+meta.Name, s.cfg.RcloneSyncInterval, filepath.Join(layout.Logs, "rclone-sync.log"), func(ctx context.Context, w io.Writer) error {
		return s.runPeriodicSyncOnce(ctx, meta, w)
	})
}

func (s *Server) runPeriodicSyncOnce(ctx context.Context, meta volume.Metadata, w io.Writer) error {
	layout := s.layout(meta.Name)
	token, err := (AuthClient{
		ServerURL: s.cfg.ServerURL,
		NodeID:    s.cfg.NodeID,
		Secret:    s.cfg.NodeSecret,
	}).Token(ctx)
	if err != nil {
		return err
	}
	endpoint := s.cfg.RcloneEndpoint
	if endpoint == "" {
		endpoint = token.Endpoint
	}
	if endpoint == "" {
		endpoint = s.cfg.ServerURL
	}
	configPath, err := WriteRcloneWebDAVConfig(RcloneWebDAVConfig{
		Name:      meta.Name,
		Endpoint:  endpoint,
		ConfigDir: filepath.Join(layout.Root, "config", "rclone-sync"),
	})
	if err != nil {
		return err
	}
	if err := s.ensureRcloneVolumeRemote(ctx, configPath, meta, token.Value); err != nil {
		return err
	}
	args, err := RcloneSyncSpec{
		ConfigPath: configPath,
		RemoteName: meta.Name,
		Source:     s.syncSource(meta),
		Target:     s.syncTarget(meta),
		Token:      token.Value,
		ExtraArgs:  fields(s.cfg.RcloneExtraArgs),
	}.Args()
	if err != nil {
		return err
	}
	binary := s.cfg.RcloneBinary
	if binary == "" {
		binary = "rclone"
	}
	cmd := exec.CommandContext(ctx, binary, args...)
	cmd.Stdout = w
	cmd.Stderr = w
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("rclone sync failed: %w", err)
	}
	fmt.Fprintf(w, "%s sync completed for %s\n", time.Now().Format(time.RFC3339), meta.Name)
	return nil
}

func (s *Server) syncSource(meta volume.Metadata) string {
	if s.cfg.RcloneSyncSource != "" {
		return expandVolumeTemplate(s.cfg.RcloneSyncSource, meta.Name)
	}
	return s.layout(meta.Name).Mountpoint
}

func (s *Server) syncTarget(meta volume.Metadata) string {
	if s.cfg.RcloneSyncTarget != "" {
		return expandVolumeTemplate(s.cfg.RcloneSyncTarget, meta.Name)
	}
	return sanitizeRemoteName(meta.Name) + ":" + volumeRemotePath(meta.Name)
}

func expandVolumeTemplate(v string, name string) string {
	return strings.ReplaceAll(v, "{volume}", name)
}
