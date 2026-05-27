package daemon

import (
	"testing"

	"cs-storage/internal/volume"
)

func TestLayoutDirsForRealtimeCryptUsesEncryptedLocalCache(t *testing.T) {
	s := &Server{cfg: Config{RootDir: "/root"}}
	meta := volume.Metadata{Name: "app", Options: volume.Options{Mode: "shared", Write: "single", Engine: "auto", Crypt: true}}
	layout := s.layout(meta.Name)
	got := layoutDirsFor(meta, layout)
	if !containsDir(got, layout.Cipher) || !containsDir(got, layout.Cache) {
		t.Fatalf("realtime encrypted layout must create encrypted cache dirs: %#v", got)
	}
	if containsDir(got, layout.Remote) {
		t.Fatalf("realtime encrypted layout must not use remote cipher tree: %#v", got)
	}
	if !containsDir(got, layout.Mountpoint) {
		t.Fatalf("realtime encrypted layout missing mount dirs: %#v", got)
	}
}

func TestLayoutDirsForRealtimePlainDoesNotCreateUnusedRemoteTree(t *testing.T) {
	s := &Server{cfg: Config{RootDir: "/root"}}
	meta := volume.Metadata{Name: "app", Options: volume.Options{Mode: "private", Write: "single", Engine: "auto", Crypt: false}}
	layout := s.layout(meta.Name)
	got := layoutDirsFor(meta, layout)
	if containsDir(got, layout.Remote) || containsDir(got, layout.Cipher) {
		t.Fatalf("plaintext realtime layout should only create active mount tree: %#v", got)
	}
	if !containsDir(got, layout.Mountpoint) {
		t.Fatalf("plaintext realtime layout missing mountpoint: %#v", got)
	}
}

func containsDir(dirs []string, want string) bool {
	for _, dir := range dirs {
		if dir == want {
			return true
		}
	}
	return false
}
