package volume

import (
	"os"
	"path/filepath"
	"testing"
)

func TestStorePersistsDriverOptionsExceptFlush(t *testing.T) {
	path := filepath.Join(t.TempDir(), "volumes.json")
	store, err := NewStore(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Upsert(Metadata{
		Name:       "app",
		Mountpoint: "/mnt/app",
		Options:    Options{Mode: "shared", Write: "multi", Engine: "sqlite", Crypt: false, Backup: true, Flush: true},
	}); err != nil {
		t.Fatal(err)
	}
	got, ok := store.Get("app")
	if !ok {
		t.Fatal("metadata missing")
	}
	want := Options{Mode: "shared", Write: "multi", Engine: "sqlite", Crypt: false, Backup: true}
	if got.Options != want {
		t.Fatalf("unexpected stored options: got %#v want %#v", got.Options, want)
	}
	reloaded, err := NewStore(path)
	if err != nil {
		t.Fatal(err)
	}
	got, ok = reloaded.Get("app")
	if !ok {
		t.Fatal("reloaded metadata missing")
	}
	if got.Options != want {
		t.Fatalf("unexpected reloaded options: got %#v want %#v", got.Options, want)
	}
}

func TestStoreLoadsStringBackupOption(t *testing.T) {
	path := filepath.Join(t.TempDir(), "volumes.json")
	if err := os.WriteFile(path, []byte(`{"app":{"name":"app","mountpoint":"/mnt/app","options":{"mode":"private","write":"single","engine":"auto","crypt":true,"backup":"true"}}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := NewStore(path)
	if err != nil {
		t.Fatal(err)
	}
	got, ok := store.Get("app")
	if !ok {
		t.Fatal("metadata missing")
	}
	if !got.Options.Backup {
		t.Fatalf("string backup option was not loaded: %#v", got.Options)
	}
}
