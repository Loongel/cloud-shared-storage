package daemon

import "cs-storage/internal/volume"

func (s *Server) stopRealtime(meta volume.Metadata) error {
	layout := s.layout(meta.Name)
	_ = s.procs.Stop("rclone:" + meta.Name)
	if err := unmountPath(layout.Mountpoint); err != nil {
		return err
	}
	if meta.Options.Crypt {
		_ = s.procs.Stop("gocryptfs:" + meta.Name)
		return unmountPath(layout.Cache)
	}
	return nil
}

func (s *Server) stopSharedMulti(meta volume.Metadata) error {
	layout := s.layout(meta.Name)
	if s.syncs != nil {
		s.syncs.Stop("rclone-sync:" + meta.Name)
	}
	switch PlanPipeline(meta.Options).Kind {
	case PipelineSharedSQLite:
		_ = s.procs.Stop("litefs:" + meta.Name)
		return unmountPath(layout.Mountpoint)
	case PipelineSharedStatic:
		_ = s.procs.Stop("gluster:" + meta.Name)
		return unmountPath(layout.Mountpoint)
	default:
		_ = s.procs.Stop("router:" + meta.Name)
		if err := unmountPath(layout.Mountpoint); err != nil {
			return err
		}
		_ = s.procs.Stop("litefs-backend:" + meta.Name)
		if err := unmountPath(layout.LiteFSMount); err != nil {
			return err
		}
		_ = s.procs.Stop("gluster-backend:" + meta.Name)
		if err := unmountPath(layout.Gluster); err != nil {
			return err
		}
		return nil
	}
}

func (s *Server) stopVolumeProcesses(meta volume.Metadata) error {
	s.stopPeriodicBackup(meta)
	if err := s.snapshotIfEnabled(meta); err != nil {
		return err
	}
	if meta.Options.NeedsRealtimeRclone() {
		return s.stopRealtime(meta)
	}
	return s.stopSharedMulti(meta)
}
