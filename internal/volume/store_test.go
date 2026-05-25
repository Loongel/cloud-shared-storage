package volume

import (
	"path/filepath"
	"testing"
)

func TestStoreDoesNotPersistDriverOptions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "volumes.json")
	store, err := NewStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Upsert(Metadata{
		Name:       "app",
		Mountpoint: "/mnt/app",
		Options:    Options{Mode: "shared", Write: "multi", Engine: "sqlite", Crypt: false, Backup: "auto", Flush: true},
	}); err != nil {
		t.Fatal(err)
	}
	got, ok := store.Get("app")
	if !ok {
		t.Fatal("metadata missing")
	}
	if got.Options != (Options{}) {
		t.Fatalf("stored metadata must not retain volume options: %#v", got.Options)
	}
	reloaded, err := NewStore(path)
	if err != nil {
		t.Fatal(err)
	}
	got, ok = reloaded.Get("app")
	if !ok {
		t.Fatal("reloaded metadata missing")
	}
	if got.Options != (Options{}) {
		t.Fatalf("persisted metadata must not include volume options: %#v", got.Options)
	}
}
