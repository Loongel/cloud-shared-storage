package admin

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os/exec"
	"sort"
	"strings"
)

type ListBackupsOptions struct {
	Source       string
	RcloneBinary string
	RcloneConfig string
	ExtraArgs    []string
}

func ListBackups(ctx context.Context, opts ListBackupsOptions) ([]string, error) {
	if opts.Source == "" {
		return nil, errors.New("backup source is required")
	}
	if opts.RcloneBinary == "" {
		opts.RcloneBinary = "rclone"
	}
	args := []string{"lsf", opts.Source, "--dirs-only"}
	if opts.RcloneConfig != "" {
		args = append([]string{"--config", opts.RcloneConfig}, args...)
	}
	args = append(args, opts.ExtraArgs...)
	cmd := exec.CommandContext(ctx, opts.RcloneBinary, args...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("rclone list backups failed: %w: %s", err, strings.TrimSpace(out.String()))
	}
	var backups []string
	for _, line := range strings.Split(out.String(), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		backups = append(backups, strings.TrimSuffix(line, "/"))
	}
	return backups, nil
}

type LatestBackupSourceOptions struct {
	Root         string
	Volume       string
	RcloneBinary string
	RcloneConfig string
	ExtraArgs    []string
}

func LatestBackupSource(ctx context.Context, opts LatestBackupSourceOptions) (string, string, error) {
	if opts.Root == "" {
		return "", "", errors.New("backup root is required")
	}
	if opts.Volume == "" {
		return "", "", errors.New("volume is required")
	}
	volumeRoot := JoinRemotePath(opts.Root, opts.Volume)
	backups, err := ListBackups(ctx, ListBackupsOptions{
		Source:       volumeRoot,
		RcloneBinary: opts.RcloneBinary,
		RcloneConfig: opts.RcloneConfig,
		ExtraArgs:    opts.ExtraArgs,
	})
	if err != nil {
		return "", "", err
	}
	latest, err := LatestBackupName(backups)
	if err != nil {
		return "", "", err
	}
	return JoinRemotePath(volumeRoot, latest), latest, nil
}

func LatestBackupName(backups []string) (string, error) {
	cleaned := make([]string, 0, len(backups))
	for _, backup := range backups {
		backup = strings.Trim(strings.TrimSpace(backup), "/")
		if backup != "" {
			cleaned = append(cleaned, backup)
		}
	}
	if len(cleaned) == 0 {
		return "", errors.New("no backups found")
	}
	sort.Strings(cleaned)
	return cleaned[len(cleaned)-1], nil
}

func JoinRemotePath(root string, elems ...string) string {
	root = strings.TrimRight(root, "/")
	parts := make([]string, 0, len(elems))
	for _, elem := range elems {
		elem = strings.Trim(elem, "/")
		if elem != "" {
			parts = append(parts, elem)
		}
	}
	if len(parts) == 0 {
		return root
	}
	return root + "/" + strings.Join(parts, "/")
}
