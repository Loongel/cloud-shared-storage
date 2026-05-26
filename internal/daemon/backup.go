package daemon

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"cs-storage/internal/volume"
)

func (s *Server) ensurePeriodicBackup(_ context.Context, meta volume.Metadata) error {
	if !meta.Options.Backup {
		return nil
	}
	interval := s.cfg.KopiaSnapshotInterval
	if interval <= 0 {
		return nil
	}
	if s.cfg.KopiaRepository == "" && s.cfg.KopiaConfigPath == "" {
		return fmt.Errorf("cs.backup=true requires CS_KOPIA_REPOSITORY or CS_KOPIA_CONFIG_PATH")
	}
	if s.syncs == nil {
		s.syncs = NewPeriodicSyncManager()
	}
	layout := s.layout(meta.Name)
	return s.syncs.Start("kopia:"+meta.Name, interval, filepath.Join(layout.Logs, "kopia.log"), func(ctx context.Context, w io.Writer) error {
		return s.runKopiaSnapshot(ctx, meta, w)
	})
}

func (s *Server) stopPeriodicBackup(meta volume.Metadata) {
	if s.syncs != nil {
		s.syncs.Stop("kopia:" + meta.Name)
	}
}

func (s *Server) snapshotIfEnabled(meta volume.Metadata) error {
	if !meta.Options.Backup {
		return nil
	}
	if s.cfg.KopiaRepository == "" && s.cfg.KopiaConfigPath == "" {
		return fmt.Errorf("cs.backup=true requires CS_KOPIA_REPOSITORY or CS_KOPIA_CONFIG_PATH")
	}
	layout := s.layout(meta.Name)
	if err := os.MkdirAll(layout.Logs, 0o700); err != nil {
		return err
	}
	logPath := filepath.Join(layout.Logs, "kopia.log")
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	return s.runKopiaSnapshot(context.Background(), meta, f)
}

func (s *Server) runKopiaSnapshot(ctx context.Context, meta volume.Metadata, w io.Writer) error {
	layout := s.layout(meta.Name)
	if s.cfg.KopiaPolicyArgs != "" {
		args := append([]string{"policy", "set", layout.Mountpoint}, fields(s.cfg.KopiaPolicyArgs)...)
		if err := s.runKopia(ctx, args, w); err != nil {
			return fmt.Errorf("kopia policy set failed: %w", err)
		}
		fmt.Fprintf(w, "%s kopia policy updated for %s\n", time.Now().Format(time.RFC3339), meta.Name)
	}
	args := []string{"snapshot", "create", layout.Mountpoint, "--description", "cs-storage:" + meta.Name}
	args = append(args, fields(s.cfg.KopiaExtraArgs)...)
	if err := s.runKopia(ctx, args, w); err != nil {
		return fmt.Errorf("kopia snapshot failed: %w", err)
	}
	fmt.Fprintf(w, "%s kopia snapshot completed for %s\n", time.Now().Format(time.RFC3339), meta.Name)
	return nil
}

func (s *Server) runKopia(ctx context.Context, args []string, w io.Writer) error {
	binary := s.cfg.KopiaBinary
	if binary == "" {
		binary = "kopia"
	}
	cmdArgs := []string{}
	if s.cfg.KopiaConfigPath != "" {
		cmdArgs = append(cmdArgs, "--config-file", s.cfg.KopiaConfigPath)
	}
	cmdArgs = append(cmdArgs, args...)
	cmd := exec.CommandContext(ctx, binary, cmdArgs...)
	cmd.Env = os.Environ()
	if s.cfg.KopiaRepository != "" {
		cmd.Env = append(cmd.Env, "KOPIA_REPOSITORY="+s.cfg.KopiaRepository)
	}
	if s.cfg.KopiaConfigPath != "" {
		cmd.Env = append(cmd.Env, "KOPIA_CONFIG_PATH="+s.cfg.KopiaConfigPath)
	}
	if s.cfg.KopiaPassword != "" {
		cmd.Env = append(cmd.Env, "KOPIA_PASSWORD="+s.cfg.KopiaPassword)
	}
	cmd.Stdout = w
	cmd.Stderr = w
	return cmd.Run()
}
