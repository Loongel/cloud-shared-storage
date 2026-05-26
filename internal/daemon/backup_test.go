package daemon

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"cs-storage/internal/volume"
)

func TestEnsurePeriodicBackupStartsWhenEnabled(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "kopia")
	marker := filepath.Join(t.TempDir(), "runs")
	script := "#!/bin/sh\nprintf run >> '" + marker + "'\n"
	if err := os.WriteFile(bin, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	s := &Server{cfg: Config{RootDir: t.TempDir(), KopiaBinary: bin, KopiaConfigPath: filepath.Join(t.TempDir(), "repo.config"), KopiaSnapshotInterval: time.Millisecond}, syncs: NewPeriodicSyncManager()}
	meta := volume.Metadata{Name: "vol", Options: volume.Options{Backup: true}}
	if err := s.ensurePeriodicBackup(context.Background(), meta); err != nil {
		t.Fatal(err)
	}
	defer s.stopPeriodicBackup(meta)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if b, _ := os.ReadFile(marker); len(b) > 0 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("periodic backup did not run")
}

func TestRunKopiaSnapshotAppliesPolicyBeforeSnapshot(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "kopia")
	logPath := filepath.Join(dir, "commands")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" + logPath + "'\n"
	if err := os.WriteFile(bin, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	s := &Server{cfg: Config{
		RootDir:         dir,
		KopiaBinary:     bin,
		KopiaConfigPath: filepath.Join(dir, "repo.config"),
		KopiaPolicyArgs: "--keep-latest=24 --keep-daily=7",
	}}
	meta := volume.Metadata{Name: "vol", Options: volume.Options{Backup: true}}
	if err := os.MkdirAll(s.layout(meta.Name).Mountpoint, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := s.runKopiaSnapshot(context.Background(), meta, os.Stderr); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected policy and snapshot commands, got %q", b)
	}
	if !strings.Contains(lines[0], "--config-file "+s.cfg.KopiaConfigPath+" policy set") || !strings.Contains(lines[0], "--keep-latest=24 --keep-daily=7") {
		t.Fatalf("unexpected policy command: %q", lines[0])
	}
	if !strings.Contains(lines[1], "snapshot create") || !strings.Contains(lines[1], "--description cs-storage:vol") {
		t.Fatalf("unexpected snapshot command: %q", lines[1])
	}
}

func TestEnsurePeriodicBackupNoopsWhenDisabled(t *testing.T) {
	s := &Server{cfg: Config{RootDir: t.TempDir(), KopiaConfigPath: filepath.Join(t.TempDir(), "repo.config")}, syncs: NewPeriodicSyncManager()}
	meta := volume.Metadata{Name: "vol", Options: volume.Options{Backup: true}}
	if err := s.ensurePeriodicBackup(context.Background(), meta); err != nil {
		t.Fatal(err)
	}
	if len(s.syncs.cancel) != 0 {
		t.Fatalf("unexpected periodic backup job: %#v", s.syncs.cancel)
	}
}
