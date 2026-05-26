package routerfuse

import (
	"context"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"

	"cs-storage/internal/router"

	"github.com/hanwen/go-fuse/v2/fuse"
)

func TestRootBackingUsesRouterPolicy(t *testing.T) {
	lite := t.TempDir()
	gluster := t.TempDir()
	root, err := NewRoot(lite, gluster)
	if err != nil {
		t.Fatal(err)
	}
	if got := root.backing("/app/config.yml"); got != filepath.Join(gluster, "/app/config.yml") {
		t.Fatalf("expected gluster backing, got %s", got)
	}
	if got := root.backing("/app/data/main.db"); got != filepath.Join(lite, "app__data__main.db") {
		t.Fatalf("expected litefs backing, got %s", got)
	}
	if got := root.Router.Route("/app/data/other.txt"); got != router.EngineLiteFS {
		t.Fatalf("expected sqlite parent directory to stay pinned, got %s", got)
	}
}

func TestNodeSetattrUpdatesBackingFile(t *testing.T) {
	lite := t.TempDir()
	gluster := t.TempDir()
	root, err := NewRoot(lite, gluster)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(gluster, "docs/file.txt")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("0123456789"), 0o600); err != nil {
		t.Fatal(err)
	}

	mtime := time.Unix(1710000000, 123000000)
	in := &fuse.SetAttrIn{}
	in.Valid = fuse.FATTR_MODE | fuse.FATTR_SIZE | fuse.FATTR_MTIME
	in.Mode = 0o644
	in.Size = 4
	in.Mtime = uint64(mtime.Unix())
	in.Mtimensec = uint32(mtime.Nanosecond())

	var out fuse.AttrOut
	if errno := root.node("/docs/file.txt").Setattr(context.Background(), nil, in, &out); errno != 0 {
		t.Fatalf("Setattr errno=%v", errno)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0o644 {
		t.Fatalf("mode=%#o", st.Mode().Perm())
	}
	if st.Size() != 4 {
		t.Fatalf("size=%d", st.Size())
	}
	if !st.ModTime().Equal(mtime) {
		t.Fatalf("mtime=%s want %s", st.ModTime(), mtime)
	}
}

func TestSymlinkAndReadlinkUseRoutedBacking(t *testing.T) {
	lite := t.TempDir()
	gluster := t.TempDir()
	root, err := NewRoot(lite, gluster)
	if err != nil {
		t.Fatal(err)
	}
	if _, errno := root.symlink("../target.txt", "/links/current"); errno != 0 {
		t.Fatalf("Symlink errno=%v", errno)
	}
	linkPath := filepath.Join(gluster, "links/current")
	if got, err := os.Readlink(linkPath); err != nil || got != "../target.txt" {
		t.Fatalf("backing readlink got %q err=%v", got, err)
	}
	got, errno := root.node("/links/current").Readlink(context.Background())
	if errno != 0 {
		t.Fatalf("Readlink errno=%v", errno)
	}
	if string(got) != "../target.txt" {
		t.Fatalf("Readlink got %q", string(got))
	}
}

func TestHardlinkRejectsCrossEngineRoutes(t *testing.T) {
	lite := t.TempDir()
	gluster := t.TempDir()
	root, err := NewRoot(lite, gluster)
	if err != nil {
		t.Fatal(err)
	}
	sqlitePath := root.backing("/db/main.db")
	if err := os.MkdirAll(filepath.Dir(sqlitePath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(gluster, "docs"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(sqlitePath, []byte("sqlite"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, errno := root.link(root.node("/db/main.db"), "/docs/main.db.link"); errno != syscall.EXDEV {
		t.Fatalf("cross-engine hardlink errno=%v want EXDEV", errno)
	}
	if _, err := os.Lstat(filepath.Join(gluster, "docs/main.db.link")); !os.IsNotExist(err) {
		t.Fatalf("cross-engine hardlink should not create target, err=%v", err)
	}
}

func TestHardlinkWithinSameEngine(t *testing.T) {
	lite := t.TempDir()
	gluster := t.TempDir()
	root, err := NewRoot(lite, gluster)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(gluster, "docs"), 0o700); err != nil {
		t.Fatal(err)
	}
	source := filepath.Join(gluster, "docs/file.txt")
	if err := os.WriteFile(source, []byte("payload"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, errno := root.link(root.node("/docs/file.txt"), "/docs/file-hard.txt"); errno != 0 {
		t.Fatalf("Link errno=%v", errno)
	}
	linked := filepath.Join(gluster, "docs/file-hard.txt")
	data, err := os.ReadFile(linked)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "payload" {
		t.Fatalf("linked data=%q", string(data))
	}
	var st syscall.Stat_t
	if err := syscall.Lstat(source, &st); err != nil {
		t.Fatal(err)
	}
	if st.Nlink < 2 {
		t.Fatalf("nlink=%d", st.Nlink)
	}
}
