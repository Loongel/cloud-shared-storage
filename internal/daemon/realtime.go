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
	if meta.Options.Crypt {
		if err := s.ensureEncryptedCache(meta); err != nil {
			return err
		}
	}
	token, err := (AuthClient{
		ServerURL: s.cfg.ServerURL,
		NodeID:    s.cfg.NodeID,
		Secret:    s.cfg.NodeSecret,
		Namespace: authNamespace(meta),
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
	if err := s.ensureRcloneVolumeRemote(ctx, configPath, meta, token.Value); err != nil {
		return err
	}
	spec := RcloneMountSpec{
		ConfigPath:      configPath,
		RemoteName:      meta.Name,
		RemotePath:      volumeRemotePath(meta.Name),
		Mountpoint:      layout.Mountpoint,
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
	if err := waitForManagedMountpoint(s.procs, "rclone:"+meta.Name, layout.Mountpoint, 10*time.Second); err != nil {
		return err
	}
	return nil
}

func (s *Server) resetRealtimeRemote(ctx context.Context, meta volume.Metadata) error {
	if !meta.Options.NeedsRealtimeRclone() {
		return nil
	}
	if s.cfg.ServerURL == "" || s.cfg.NodeID == "" || s.cfg.NodeSecret == "" {
		return fmt.Errorf("realtime rclone flush requires CS_SERVER_URL, CS_NODE_ID, and CS_NODE_SECRET_KEY")
	}
	layout := s.layout(meta.Name)
	token, err := (AuthClient{
		ServerURL: s.cfg.ServerURL,
		NodeID:    s.cfg.NodeID,
		Secret:    s.cfg.NodeSecret,
		Namespace: authNamespace(meta),
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
	if err := s.runRcloneRemoteCommand(ctx, configPath, meta, token.Value, "purge", volumeRemotePath(meta.Name)); err != nil && !isRcloneMissingPathError(err) {
		return err
	}
	return s.ensureRcloneVolumeRemote(ctx, configPath, meta, token.Value)
}

func authNamespace(meta volume.Metadata) string {
	if meta.Options.Mode == "shared" {
		return "shared"
	}
	return ""
}

func (s *Server) ensureRcloneVolumeRemote(ctx context.Context, configPath string, meta volume.Metadata, token string) error {
	for _, path := range []string{"volumes", volumeRemotePath(meta.Name)} {
		if err := s.runRcloneRemoteCommand(ctx, configPath, meta, token, "mkdir", path); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) runRcloneRemoteCommand(ctx context.Context, configPath string, meta volume.Metadata, token string, op string, path string) error {
	binary := s.cfg.RcloneBinary
	if binary == "" {
		binary = "rclone"
	}
	remote := sanitizeRemoteName(meta.Name) + ":"
	args := []string{"--config", configPath, "--header", "Authorization: Bearer " + token, op, remote + strings.TrimLeft(path, "/")}
	cmd := exec.CommandContext(ctx, binary, args...)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("rclone %s %s failed: %w: %s", op, path, err, string(out))
	}
	return nil
}

func isRcloneMissingPathError(err error) bool {
	text := strings.ToLower(err.Error())
	return strings.Contains(text, "not found") || strings.Contains(text, "directory not found") || strings.Contains(text, "object not found")
}

func (s *Server) ensureEncryptedCache(meta volume.Metadata) error {
	if s.cfg.GocryptfsPassword == "" {
		return fmt.Errorf("cs.crypt=true requires CS_GOCRYPTFS_PASSWORD")
	}
	layout := s.layout(meta.Name)
	if isMountpointFunc(layout.Cache) {
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
	if err := resetUnmountedMountpointDir(layout.Cache); err != nil {
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
	args := []string{"-passfile", passfile, layout.Cipher, layout.Cache}
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
	if err := waitForManagedMountpoint(s.procs, "gocryptfs:"+meta.Name, layout.Cache, 10*time.Second); err != nil {
		return err
	}
	return nil
}

func resetUnmountedMountpointDir(path string) error {
	if path == "" || isMountpointFunc(path) {
		return nil
	}
	if err := os.RemoveAll(path); err != nil {
		return err
	}
	return os.MkdirAll(path, 0o700)
}

func fields(v string) []string {
	if strings.TrimSpace(v) == "" {
		return nil
	}
	return strings.Fields(v)
}
