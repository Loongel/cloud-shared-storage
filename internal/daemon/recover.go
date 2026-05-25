package daemon

import (
	"log"

	"cs-storage/internal/volume"
)

func (s *Server) recoverState() {
	vols := s.store.List()
	for _, meta := range vols {
		if len(meta.MountIDs) == 0 {
			continue
		}
		// Volume routing options are request-scoped and are not persisted in
		// metadata. Non-managed mounts cannot be safely reconstructed at daemon
		// startup without a fresh Docker request carrying current options/labels.
		if s.cfg.RecoverMounts {
			log.Printf("cannot recover non-managed mount for %s without request options; clearing refs", meta.Name)
		}
		s.clearMountRefs(meta)
	}
}

func (s *Server) clearMountRefs(meta volume.Metadata) {
	meta.MountIDs = nil
	if err := s.store.Upsert(meta); err != nil {
		log.Printf("clear stale mount refs for %s failed: %v", meta.Name, err)
	}
}
