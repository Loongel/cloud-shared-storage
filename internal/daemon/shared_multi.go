package daemon

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"cs-storage/internal/volume"
)

func (s *Server) ensureMountReady(_ string, meta volume.Metadata) error {
	if meta.Options.NeedsRealtimeRclone() {
		return nil
	}
	if err := s.ensureSharedMulti(meta); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return s.ensurePeriodicSync(ctx, meta)
}

func (s *Server) ensureSharedMulti(meta volume.Metadata) error {
	plan := PlanPipeline(meta.Options)
	switch plan.Kind {
	case PipelineSharedStatic:
		return s.ensureGluster(meta)
	case PipelineSharedSQLite:
		return s.ensureLiteFS(meta)
	case PipelineSharedAuto:
		return s.ensureAutoRouter(meta)
	default:
		return fmt.Errorf("unsupported shared multi pipeline %s", plan.Kind)
	}
}

func (s *Server) ensureGluster(meta volume.Metadata) error {
	if s.cfg.GlusterRemote == "" {
		return fmt.Errorf("cs.engine=static requires CS_GLUSTER_REMOTE")
	}
	layout := s.layout(meta.Name)
	if isMountpointFunc(layout.Mountpoint) {
		return nil
	}
	binary := s.cfg.GlusterBinary
	if binary == "" {
		binary = "mount.glusterfs"
	}
	args := append(fields(s.cfg.GlusterExtraArgs), s.cfg.GlusterRemote, layout.Mountpoint)
	if err := s.procs.Start(ProcessSpec{
		Key:     "gluster:" + meta.Name,
		Binary:  binary,
		Args:    args,
		LogPath: filepath.Join(layout.Logs, "gluster.log"),
		Restart: true,
	}); err != nil {
		return err
	}
	if !waitForMountpoint(layout.Mountpoint, 10*time.Second) {
		return fmt.Errorf("gluster mount did not become ready at %s", layout.Mountpoint)
	}
	return nil
}

func (s *Server) ensureLiteFS(meta volume.Metadata) error {
	layout := s.layout(meta.Name)
	if isMountpointFunc(layout.Mountpoint) {
		return nil
	}
	binary := s.cfg.LiteFSBinary
	if binary == "" {
		binary = "litefs"
	}
	configPath := s.cfg.LiteFSConfig
	if configPath == "" {
		var err error
		configPath, err = s.writeLiteFSConfig(meta, layout.Mountpoint, layout.LiteFSData)
		if err != nil {
			return err
		}
	}
	if err := s.procs.Start(ProcessSpec{
		Key:     "litefs:" + meta.Name,
		Binary:  binary,
		Args:    []string{"mount", "-config", configPath},
		Env:     s.liteFSEnv(),
		LogPath: filepath.Join(layout.Logs, "litefs.log"),
		Restart: true,
	}); err != nil {
		return err
	}
	if err := waitForManagedMountpoint(s.procs, "litefs:"+meta.Name, layout.Mountpoint, 10*time.Second); err != nil {
		return err
	}
	return nil
}

func (s *Server) writeLiteFSConfig(meta volume.Metadata, fuseDir string, dataDir string) (string, error) {
	layout := s.layout(meta.Name)
	if err := os.MkdirAll(layout.Config, 0o700); err != nil {
		return "", err
	}
	httpAddr := s.cfg.LiteFSHTTPAddr
	if httpAddr == "" {
		httpAddr = ":20202"
	}
	leaseType := s.cfg.LiteFSLeaseType
	if leaseType == "" {
		leaseType = "static"
	}
	if s.cfg.LiteFSAdvertiseURL == "" {
		return "", fmt.Errorf("LiteFS generated config requires CS_LITEFS_ADVERTISE_URL")
	}
	if leaseType == "consul" && s.cfg.LiteFSConsulURL == "" {
		return "", fmt.Errorf("LiteFS consul lease requires CS_LITEFS_CONSUL_URL")
	}
	var b strings.Builder
	fmt.Fprintf(&b, "fuse:\n  dir: %s\n", quoteYAML(fuseDir))
	fmt.Fprintf(&b, "data:\n  dir: %s\n", quoteYAML(dataDir))
	fmt.Fprintf(&b, "http:\n  addr: %s\n", quoteYAML(httpAddr))
	fmt.Fprintf(&b, "lease:\n  type: %s\n", quoteYAML(leaseType))
	fmt.Fprintf(&b, "  advertise-url: %s\n", quoteYAML(s.cfg.LiteFSAdvertiseURL))
	if s.cfg.LiteFSCandidate {
		fmt.Fprintf(&b, "  candidate: true\n")
	}
	if s.cfg.LiteFSHostname != "" {
		fmt.Fprintf(&b, "  hostname: %s\n", quoteYAML(s.cfg.LiteFSHostname))
	}
	if s.cfg.LiteFSPromote {
		fmt.Fprintf(&b, "  promote: true\n")
	}
	if s.cfg.LiteFSConsulURL != "" {
		key := s.cfg.LiteFSConsulKey
		if key == "" {
			key = "cs-storage/litefs/" + meta.Name
		}
		fmt.Fprintf(&b, "  consul:\n")
		fmt.Fprintf(&b, "    url: %s\n", quoteYAML(s.cfg.LiteFSConsulURL))
		fmt.Fprintf(&b, "    key: %s\n", quoteYAML(key))
		if s.cfg.LiteFSConsulTTL != "" {
			fmt.Fprintf(&b, "    ttl: %s\n", quoteYAML(s.cfg.LiteFSConsulTTL))
		}
		if s.cfg.LiteFSConsulLockDelay != "" {
			fmt.Fprintf(&b, "    lock-delay: %s\n", quoteYAML(s.cfg.LiteFSConsulLockDelay))
		}
	}
	path := filepath.Join(layout.Config, "litefs.yml")
	return path, os.WriteFile(path, []byte(b.String()), 0o600)
}

func (s *Server) liteFSEnv() []string {
	if s.cfg.LiteFSConsulToken == "" {
		return nil
	}
	return []string{"CONSUL_HTTP_TOKEN=" + s.cfg.LiteFSConsulToken}
}

func quoteYAML(v string) string {
	return "\"" + strings.ReplaceAll(v, "\"", "\\\"") + "\""
}

func (s *Server) ensureAutoRouter(meta volume.Metadata) error {
	layout := s.layout(meta.Name)
	if isMountpointFunc(layout.Mountpoint) {
		return nil
	}
	if err := s.ensureLiteFSBackend(meta); err != nil {
		return err
	}
	if err := s.ensureGlusterBackend(meta); err != nil {
		return err
	}
	binary := s.cfg.RouterBinary
	if binary == "" {
		binary = "cs-storage-router"
	}
	args := []string{"-mountpoint", layout.Mountpoint, "-litefs", layout.LiteFSMount, "-gluster", layout.Gluster}
	args = append(args, fields(s.cfg.RouterExtraArgs)...)
	if err := s.procs.Start(ProcessSpec{
		Key:     "router:" + meta.Name,
		Binary:  binary,
		Args:    args,
		LogPath: filepath.Join(layout.Logs, "router.log"),
		Restart: true,
	}); err != nil {
		return err
	}
	if err := waitForManagedMountpoint(s.procs, "router:"+meta.Name, layout.Mountpoint, 10*time.Second); err != nil {
		return err
	}
	return nil
}

func (s *Server) ensureGlusterBackend(meta volume.Metadata) error {
	if s.cfg.GlusterRemote == "" {
		return fmt.Errorf("cs.engine=auto requires CS_GLUSTER_REMOTE")
	}
	layout := s.layout(meta.Name)
	if isMountpointFunc(layout.Gluster) {
		return nil
	}
	binary := s.cfg.GlusterBinary
	if binary == "" {
		binary = "mount.glusterfs"
	}
	args := append(fields(s.cfg.GlusterExtraArgs), s.cfg.GlusterRemote, layout.Gluster)
	if err := s.procs.Start(ProcessSpec{
		Key:     "gluster-backend:" + meta.Name,
		Binary:  binary,
		Args:    args,
		LogPath: filepath.Join(layout.Logs, "gluster-backend.log"),
		Restart: true,
	}); err != nil {
		return err
	}
	if !waitForMountpoint(layout.Gluster, 10*time.Second) {
		return fmt.Errorf("gluster backend mount did not become ready at %s", layout.Gluster)
	}
	return nil
}

func (s *Server) ensureLiteFSBackend(meta volume.Metadata) error {
	layout := s.layout(meta.Name)
	if isMountpointFunc(layout.LiteFSMount) {
		return nil
	}
	binary := s.cfg.LiteFSBinary
	if binary == "" {
		binary = "litefs"
	}
	configPath := filepath.Join(layout.Config, "litefs-auto.yml")
	if s.cfg.LiteFSConfig != "" {
		configPath = s.cfg.LiteFSConfig
	} else {
		var err error
		configPath, err = s.writeLiteFSConfig(meta, layout.LiteFSMount, layout.LiteFSData)
		if err != nil {
			return err
		}
	}
	if err := s.procs.Start(ProcessSpec{
		Key:     "litefs-backend:" + meta.Name,
		Binary:  binary,
		Args:    []string{"mount", "-config", configPath},
		Env:     s.liteFSEnv(),
		LogPath: filepath.Join(layout.Logs, "litefs-backend.log"),
		Restart: true,
	}); err != nil {
		return err
	}
	if err := waitForManagedMountpoint(s.procs, "litefs-backend:"+meta.Name, layout.LiteFSMount, 10*time.Second); err != nil {
		return err
	}
	return nil
}
