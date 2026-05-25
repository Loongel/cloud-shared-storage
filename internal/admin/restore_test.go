package admin

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRestoreDryRunPlansBackup(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "vol")
	if err := os.Mkdir(target, 0o700); err != nil {
		t.Fatal(err)
	}
	res, err := Restore(context.Background(), RestoreOptions{
		Source:    "remote:backup/vol",
		Target:    target,
		Timestamp: time.Date(2026, 5, 21, 12, 30, 45, 0, time.UTC),
		DryRun:    true,
	})
	if err != nil {
		t.Fatal(err)
	}
	want := target + ".BAK.20260521-123045"
	if res.BackupPath != want {
		t.Fatalf("backup path mismatch: got %q want %q", res.BackupPath, want)
	}
	if _, err := os.Stat(target); err != nil {
		t.Fatalf("dry run should not rename target: %v", err)
	}
}

func TestRestoreRequiresSourceAndTarget(t *testing.T) {
	if _, err := Restore(context.Background(), RestoreOptions{Target: "/tmp/x"}); err == nil {
		t.Fatal("expected missing source error")
	}
	if _, err := Restore(context.Background(), RestoreOptions{Source: "remote:x"}); err == nil {
		t.Fatal("expected missing target error")
	}
}
