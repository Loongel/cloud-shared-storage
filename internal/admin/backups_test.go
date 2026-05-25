package admin

import (
	"context"
	"testing"
)

func TestListBackupsRequiresSource(t *testing.T) {
	if _, err := ListBackups(context.Background(), ListBackupsOptions{}); err == nil {
		t.Fatal("expected missing source error")
	}
}

func TestLatestBackupNameUsesLexicographicLatest(t *testing.T) {
	got, err := LatestBackupName([]string{"20260521-010000/", "20260522-010000", "20260520-235959"})
	if err != nil {
		t.Fatal(err)
	}
	if got != "20260522-010000" {
		t.Fatalf("latest mismatch: %q", got)
	}
}

func TestJoinRemotePath(t *testing.T) {
	got := JoinRemotePath("remote:backups/", "/vol/", "20260522/")
	if got != "remote:backups/vol/20260522" {
		t.Fatalf("remote path mismatch: %q", got)
	}
}
