package daemon

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"cs-storage/internal/volume"
)

func TestRcloneSyncSpecArgs(t *testing.T) {
	args, err := RcloneSyncSpec{
		ConfigPath: "/tmp/rclone.conf",
		RemoteName: "vol.one",
		Source:     "/data/src",
		Token:      "jwt",
		ExtraArgs:  []string{"--checksum"},
	}.Args()
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(args, "\x00")
	for _, want := range []string{"--config", "/tmp/rclone.conf", "--header", "Authorization: Bearer jwt", "sync", "/data/src", "vol_one:", "--create-empty-src-dirs", "--checksum"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing %q in args %#v", want, args)
		}
	}
}

func TestPeriodicSyncManagerRepeatsAfterFailure(t *testing.T) {
	mgr := NewPeriodicSyncManager()
	var runs atomic.Int32
	logPath := filepath.Join(t.TempDir(), "sync.log")
	err := mgr.Start("job", time.Millisecond, logPath, func(context.Context, io.Writer) error {
		runs.Add(1)
		return os.ErrInvalid
	})
	if err != nil {
		t.Fatal(err)
	}
	defer mgr.Stop("job")
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if runs.Load() >= 2 {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("sync manager did not retry after failure, runs=%d", runs.Load())
}

func TestSyncSourceAndTargetTemplates(t *testing.T) {
	s := &Server{cfg: Config{RootDir: "/root", RcloneSyncSource: "/src/{volume}", RcloneSyncTarget: "remote:backups/{volume}"}}
	meta := testSharedMultiMeta("vol-a")
	if got := s.syncSource(meta); got != "/src/vol-a" {
		t.Fatalf("unexpected source %q", got)
	}
	if got := s.syncTarget(meta); got != "remote:backups/vol-a" {
		t.Fatalf("unexpected target %q", got)
	}
}

func TestSyncSourceUsesCipherForEncryptedSharedMulti(t *testing.T) {
	root := t.TempDir()
	s := &Server{cfg: Config{RootDir: root}}
	meta := testSharedMultiMeta("vol-a")
	meta.Options.Crypt = true
	if got, want := s.syncSource(meta), filepath.Join(root, "vol-a", "remote", "cipher"); got != want {
		t.Fatalf("unexpected encrypted sync source %q want %q", got, want)
	}
}

func TestSyncSourceTemplateOverridesEncryptedSharedMulti(t *testing.T) {
	s := &Server{cfg: Config{RootDir: "/root", RcloneSyncSource: "/src/{volume}"}}
	meta := testSharedMultiMeta("vol-a")
	meta.Options.Crypt = true
	if got := s.syncSource(meta); got != "/src/vol-a" {
		t.Fatalf("unexpected overridden encrypted sync source %q", got)
	}
}

func testSharedMultiMeta(name string) volume.Metadata {
	return volume.Metadata{
		Name: name,
		Options: volume.Options{
			Mode:   "shared",
			Write:  "multi",
			Engine: "static",
		},
	}
}
