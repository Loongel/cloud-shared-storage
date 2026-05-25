package admin

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

type RestoreOptions struct {
	Source         string
	Target         string
	RcloneBinary   string
	RcloneConfig   string
	BackupSuffix   string
	Timestamp      time.Time
	DryRun         bool
	RollbackOnFail bool
	ExtraArgs      []string
}

type RestoreResult struct {
	Source     string
	Target     string
	BackupPath string
	DryRun     bool
}

func Restore(ctx context.Context, opts RestoreOptions) (RestoreResult, error) {
	res := RestoreResult{Source: opts.Source, Target: opts.Target, DryRun: opts.DryRun}
	if opts.Source == "" {
		return res, errors.New("restore source is required")
	}
	if opts.Target == "" {
		return res, errors.New("restore target is required")
	}
	if opts.RcloneBinary == "" {
		opts.RcloneBinary = "rclone"
	}
	if opts.Timestamp.IsZero() {
		opts.Timestamp = time.Now()
	}
	if opts.BackupSuffix == "" {
		opts.BackupSuffix = ".BAK"
	}
	target, err := filepath.Abs(opts.Target)
	if err != nil {
		return res, err
	}
	res.Target = target
	if exists(target) {
		backup := backupName(target, opts.BackupSuffix, opts.Timestamp)
		if exists(backup) {
			return res, fmt.Errorf("backup path already exists: %s", backup)
		}
		res.BackupPath = backup
		if !opts.DryRun {
			if err := os.Rename(target, backup); err != nil {
				return res, fmt.Errorf("rename existing target to backup: %w", err)
			}
		}
	}
	if opts.DryRun {
		return res, nil
	}
	if err := os.MkdirAll(target, 0o700); err != nil {
		rollback(target, res.BackupPath, opts.RollbackOnFail)
		return res, err
	}
	args := []string{"copy", opts.Source, target, "--create-empty-src-dirs"}
	if opts.RcloneConfig != "" {
		args = append([]string{"--config", opts.RcloneConfig}, args...)
	}
	args = append(args, opts.ExtraArgs...)
	cmd := exec.CommandContext(ctx, opts.RcloneBinary, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		rollback(target, res.BackupPath, opts.RollbackOnFail)
		return res, fmt.Errorf("rclone restore failed: %w", err)
	}
	return res, nil
}

func backupName(target, suffix string, ts time.Time) string {
	stamp := ts.Format("20060102-150405")
	return target + suffix + "." + stamp
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func rollback(target, backup string, enabled bool) {
	if !enabled || backup == "" {
		return
	}
	_ = os.RemoveAll(target)
	_ = os.Rename(backup, target)
}
