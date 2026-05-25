package daemon

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

type RcloneWebDAVConfig struct {
	Name      string
	Endpoint  string
	ConfigDir string
}

func WriteRcloneWebDAVConfig(cfg RcloneWebDAVConfig) (string, error) {
	if cfg.Name == "" || cfg.Endpoint == "" || cfg.ConfigDir == "" {
		return "", fmt.Errorf("rclone name, endpoint, and config dir are required")
	}
	if _, err := url.ParseRequestURI(cfg.Endpoint); err != nil {
		return "", fmt.Errorf("invalid endpoint: %w", err)
	}
	if err := os.MkdirAll(cfg.ConfigDir, 0o700); err != nil {
		return "", err
	}
	path := filepath.Join(cfg.ConfigDir, "rclone.conf")
	content := fmt.Sprintf("[%s]\ntype = webdav\nurl = %s\nvendor = other\n", sanitizeRemoteName(cfg.Name), strings.TrimRight(cfg.Endpoint, "/"))
	return path, os.WriteFile(path, []byte(content), 0o600)
}

type RcloneSyncSpec struct {
	ConfigPath string
	RemoteName string
	Source     string
	Target     string
	Token      string
	ExtraArgs  []string
}

func (s RcloneSyncSpec) Args() ([]string, error) {
	if s.ConfigPath == "" || s.Source == "" || s.Token == "" {
		return nil, fmt.Errorf("rclone config path, source, and token are required")
	}
	target := s.Target
	if target == "" {
		if s.RemoteName == "" {
			return nil, fmt.Errorf("rclone remote name or target is required")
		}
		target = sanitizeRemoteName(s.RemoteName) + ":"
	}
	args := []string{
		"--config", s.ConfigPath,
		"--header", "Authorization: Bearer " + s.Token,
		"sync", s.Source, target,
		"--create-empty-src-dirs",
	}
	args = append(args, s.ExtraArgs...)
	return args, nil
}

type RcloneMountSpec struct {
	Binary          string
	ConfigPath      string
	RemoteName      string
	Mountpoint      string
	CacheDir        string
	Token           string
	VFSCacheMode    string
	VFSWriteBack    string
	VFSCacheMaxSize string
	RCAddr          string
	RCUser          string
	RCPassword      string
	ExtraArgs       []string
}

func (s RcloneMountSpec) Args() ([]string, error) {
	if s.ConfigPath == "" || s.RemoteName == "" || s.Mountpoint == "" || s.Token == "" {
		return nil, fmt.Errorf("rclone config path, remote name, mountpoint, and token are required")
	}
	cacheMode := s.VFSCacheMode
	if cacheMode == "" {
		cacheMode = "writes"
	}
	args := []string{
		"--config", s.ConfigPath,
		"--header", "Authorization: Bearer " + s.Token,
	}
	if s.RCAddr != "" {
		args = append(args, "--rc", "--rc-addr", normalizeRCAddr(s.RCAddr))
		if s.RCUser != "" || s.RCPassword != "" {
			args = append(args, "--rc-user", s.RCUser, "--rc-pass", s.RCPassword)
		}
	}
	args = append(args,
		"mount", sanitizeRemoteName(s.RemoteName)+":", s.Mountpoint,
		"--vfs-cache-mode", cacheMode,
	)
	if s.CacheDir != "" {
		args = append(args, "--cache-dir", s.CacheDir)
	}
	if s.VFSWriteBack != "" {
		args = append(args, "--vfs-write-back", s.VFSWriteBack)
	}
	if s.VFSCacheMaxSize != "" {
		args = append(args, "--vfs-cache-max-size", s.VFSCacheMaxSize)
	}
	args = append(args, s.ExtraArgs...)
	return args, nil
}

func normalizeRCAddr(addr string) string {
	if u, err := url.Parse(addr); err == nil && u.Host != "" {
		return u.Host
	}
	return addr
}

func sanitizeRemoteName(name string) string {
	var b strings.Builder
	for _, r := range name {
		if r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '_' || r == '-' {
			b.WriteRune(r)
			continue
		}
		b.WriteByte('_')
	}
	if b.Len() == 0 {
		return "cs_storage"
	}
	return b.String()
}
