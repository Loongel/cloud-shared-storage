package daemon

import (
	"context"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"cs-storage/internal/volume"
)

const daemonManagedMountID = "daemon-managed"

type managedVolumeSpec struct {
	Name string
	Opts map[string]string
}

func parseManagedVolumes(raw string) ([]managedVolumeSpec, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	parts := strings.Split(raw, ";")
	out := make([]managedVolumeSpec, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		name, optText, ok := strings.Cut(part, ":")
		name = strings.TrimSpace(name)
		if name == "" {
			return nil, fmt.Errorf("managed volume name is required")
		}
		opts := map[string]string{}
		if ok {
			for _, item := range strings.Split(optText, ",") {
				item = strings.TrimSpace(item)
				if item == "" {
					continue
				}
				k, v, ok := strings.Cut(item, "=")
				if !ok || strings.TrimSpace(k) == "" {
					return nil, fmt.Errorf("invalid managed volume option %q for %s", item, name)
				}
				opts[strings.TrimSpace(k)] = strings.TrimSpace(v)
			}
		}
		out = append(out, managedVolumeSpec{Name: name, Opts: opts})
	}
	return out, nil
}

func managedVolumeOptions(opts map[string]string) map[string]string {
	out := make(map[string]string, len(opts))
	for k, v := range opts {
		if strings.EqualFold(strings.TrimSpace(k), "flush") {
			continue
		}
		out[k] = v
	}
	return out
}

func (s *Server) startManagedVolumes() {
	specs, err := parseManagedVolumes(s.cfg.ManagedVolumes)
	if err != nil {
		log.Printf("cs-storage managed volume config error: %v", err)
		return
	}
	interval := s.cfg.ManagedEnsureInterval
	if interval <= 0 {
		interval = 30 * time.Second
	}
	for _, spec := range specs {
		spec := spec
		go s.managedVolumeLoop(context.Background(), spec, interval)
	}
}

func (s *Server) managedVolumeLoop(ctx context.Context, spec managedVolumeSpec, interval time.Duration) {
	for {
		if err := s.ensureManagedVolume(ctx, spec); err != nil {
			log.Printf("cs-storage managed volume ensure failed volume=%s: %v", spec.Name, err)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(interval):
		}
	}
}

func (s *Server) ensureManagedVolume(ctx context.Context, spec managedVolumeSpec) error {
	managedOpts := managedVolumeOptions(spec.Opts)
	opts, err := volume.ParseDriverOptions(managedOpts, nil)
	if err != nil {
		return err
	}
	// Daemon-managed volume declarations are steady-state desired config, not
	// lifecycle commands. Destructive flush is only honored by explicit create or
	// remove requests and is never executed or persisted from this path.
	opts.Flush = false
	layout := s.layout(spec.Name)
	meta := volume.Metadata{Name: spec.Name, Mountpoint: layout.Mountpoint, Options: opts}
	if existing, ok := s.store.Get(spec.Name); ok {
		meta.MountIDs = existing.MountIDs
	}
	addMountRef(&meta, daemonManagedMountID)
	err = s.withRootMutable(func() error {
		for _, dir := range []string{layout.Mountpoint, layout.Remote, layout.Cipher, layout.Cache, layout.Logs, layout.Config, layout.LiteFSData, layout.LiteFSMount, layout.Gluster, layout.LocalDisk} {
			if err := os.MkdirAll(dir, 0o700); err != nil {
				return err
			}
		}
		return s.store.Upsert(meta)
	})
	if err != nil {
		return err
	}
	if err := s.ensureRealtimeRclone(ctx, meta); err != nil {
		return err
	}
	if err := s.ensureMountReady(spec.Name, meta); err != nil {
		return err
	}
	if err := s.ensurePeriodicBackup(ctx, meta); err != nil {
		return err
	}
	if err := s.store.Upsert(meta); err != nil {
		return err
	}
	s.auditSuccess("managed-ensure", meta, daemonManagedMountID)
	log.Printf("cs-storage managed volume ready volume=%s mountpoint=%s", spec.Name, meta.Mountpoint)
	return nil
}
