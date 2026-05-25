package daemon

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"time"

	"cs-storage/internal/volume"
)

type auditRecord struct {
	Time       string          `json:"time"`
	Event      string          `json:"event"`
	Volume     string          `json:"volume,omitempty"`
	MountID    string          `json:"mount_id,omitempty"`
	Status     string          `json:"status"`
	Error      string          `json:"error,omitempty"`
	Mountpoint string          `json:"mountpoint,omitempty"`
	Options    *volume.Options `json:"options,omitempty"`
}

func (s *Server) audit(event string, meta *volume.Metadata, volumeName string, mountID string, status string, errText string) {
	path := s.cfg.AuditLogPath
	if path == "" {
		return
	}
	rec := auditRecord{Time: time.Now().UTC().Format(time.RFC3339Nano), Event: event, Volume: volumeName, MountID: mountID, Status: status, Error: errText}
	if meta != nil {
		rec.Volume = meta.Name
		rec.Mountpoint = meta.Mountpoint
		opts := meta.Options
		rec.Options = &opts
	}
	b, err := json.Marshal(rec)
	if err != nil {
		log.Printf("audit marshal failed: %v", err)
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		log.Printf("audit mkdir failed: %v", err)
		return
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		log.Printf("audit open failed: %v", err)
		return
	}
	defer f.Close()
	if _, err := f.Write(append(b, '\n')); err != nil {
		log.Printf("audit write failed: %v", err)
	}
}

func (s *Server) auditError(event string, volumeName string, mountID string, msg string) {
	s.audit(event, nil, volumeName, mountID, "error", msg)
}

func (s *Server) auditSuccess(event string, meta volume.Metadata, mountID string) {
	s.audit(event, &meta, meta.Name, mountID, "ok", "")
}
