package daemon

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"cs-storage/internal/volume"
)

func (s *Server) ensureRealtimeRclone(ctx context.Context, meta volume.Metadata) error {
	if !meta.Options.NeedsRealtimeRclone() {
		return nil
	}
	if s.cfg.ServerURL == "" || s.cfg.NodeID == "" || s.cfg.NodeSecret == "" {
		return fmt.Errorf("realtime rclone requires CS_SERVER_URL, CS_NODE_ID, and CS_NODE_SECRET_KEY")
	}
	layout := s.layout(meta.Name)
	if isMountpointFunc(layout.Mountpoint) {
		return nil
	}
	if meta.Options.Crypt && isMountpointFunc(layout.Remote) {
		return s.ensureGocryptfs(meta)
	}
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
		ConfigDir: filepath.Join(layout.Root, "config", "rclone"),
	})
	if err != nil {
		return err
	}
	mountpoint := layout.Mountpoint
	if meta.Options.Crypt {
		mountpoint = layout.Remote
	}
	spec := RcloneMountSpec{
		ConfigPath:      configPath,
		RemoteName:      meta.Name,
		Mountpoint:      mountpoint,
		CacheDir:        layout.Cache,
		Token:           token.Value,
		VFSCacheMode:    s.cfg.RcloneVFSCacheMode,
		VFSWriteBack:    s.cfg.RcloneVFSWriteBack,
		VFSCacheMaxSize: s.cfg.RcloneVFSCacheMaxSize,
		RCAddr:          s.cfg.RcloneRCAddr,
		RCUser:          s.cfg.RcloneRCUser,
		RCPassword:      s.cfg.RcloneRCPassword,
		ExtraArgs:       fields(s.cfg.RcloneExtraArgs),
	}
	args, err := spec.Args()
	if err != nil {
		return err
	}
	binary := s.cfg.RcloneBinary
	if binary == "" {
		binary = "rclone"
	}
	if err := s.procs.Start(ProcessSpec{
		Key:     "rclone:" + meta.Name,
		Binary:  binary,
		Args:    args,
		LogPath: filepath.Join(layout.Logs, "rclone.log"),
		Restart: true,
	}); err != nil {
		return err
	}
	if err := waitForManagedMountpoint(s.procs, "rclone:"+meta.Name, mountpoint, 10*time.Second); err != nil {
		return err
	}
	if meta.Options.Crypt {
		return s.ensureGocryptfs(meta)
	}
	return nil
}

func (s *Server) ensureGocryptfs(meta volume.Metadata) error {
	if s.cfg.GocryptfsPassword == "" {
		return fmt.Errorf("cs.crypt=true requires CS_GOCRYPTFS_PASSWORD")
	}
	layout := s.layout(meta.Name)
	if isMountpointFunc(layout.Mountpoint) {
		return nil
	}
	binary := s.cfg.GocryptfsBinary
	if binary == "" {
		binary = "gocryptfs"
	}
	passfile := filepath.Join(layout.Root, "config", "gocryptfs.pass")
	if err := writeSecretFile(passfile, s.cfg.GocryptfsPassword); err != nil {
		return err
	}
	if err := os.MkdirAll(layout.Cipher, 0o700); err != nil {
		return err
	}
	if !fileExists(filepath.Join(layout.Cipher, "gocryptfs.conf")) {
		cmd := exec.Command(binary, "-init", "-passfile", passfile, layout.Cipher)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
		if err := cmd.Run(); err != nil {
			return fmt.Errorf("gocryptfs init failed: %w", err)
		}
	}
	args := []string{"-passfile", passfile, layout.Cipher, layout.Mountpoint}
	if s.cfg.GocryptfsExtraArgs != "" {
		args = append(fields(s.cfg.GocryptfsExtraArgs), args...)
	}
	if err := s.procs.Start(ProcessSpec{
		Key:     "gocryptfs:" + meta.Name,
		Binary:  binary,
		Args:    args,
		LogPath: filepath.Join(layout.Logs, "gocryptfs.log"),
		Restart: true,
	}); err != nil {
		return err
	}
	if err := waitForManagedMountpoint(s.procs, "gocryptfs:"+meta.Name, layout.Mountpoint, 10*time.Second); err != nil {
		return err
	}
	return nil
}

func fields(v string) []string {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	return strings.Fields(v)
}
