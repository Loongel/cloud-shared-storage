package daemon

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"cs-storage/internal/volume"
)

func TestParseManagedVolumes(t *testing.T) {
	specs, err := parseManagedVolumes("app:cs.mode=shared,cs.write=multi,cs.engine=sqlite,cs.crypt=false;cache:cs.crypt=false")
	if err != nil {
		t.Fatal(err)
	}
	if len(specs) != 2 {
		t.Fatalf("len=%d", len(specs))
	}
	if specs[0].Name != "app" || specs[0].Opts["cs.mode"] != "shared" || specs[0].Opts["cs.write"] != "multi" || specs[0].Opts["cs.engine"] != "sqlite" || specs[0].Opts["cs.crypt"] != "false" {
		t.Fatalf("unexpected first spec: %+v", specs[0])
	}
	if specs[1].Name != "cache" || specs[1].Opts["cs.crypt"] != "false" {
		t.Fatalf("unexpected second spec: %+v", specs[1])
	}
}

func TestParseManagedVolumesRejectsBadOption(t *testing.T) {
	if _, err := parseManagedVolumes("app:cs.mode"); err == nil {
		t.Fatal("expected bad option error")
	}
}

func TestManagedVolumeOptionsDropsFlush(t *testing.T) {
	opts := managedVolumeOptions(map[string]string{"flush": "true", "cs.crypt": "false"})
	if _, ok := opts["flush"]; ok {
		t.Fatalf("managed volume options must not preserve flush: %#v", opts)
	}
	if opts["cs.crypt"] != "false" {
		t.Fatalf("non-destructive option missing: %#v", opts)
	}
}

func TestRequestMetadataUsesManagedConfigWhenRequestHasNoOptions(t *testing.T) {
	s := newTestDaemon(t)
	s.cfg.ManagedVolumes = "app:cs.mode=shared,cs.write=multi,cs.engine=sqlite,cs.crypt=false,flush=true"
	meta := volume.Metadata{Name: "app", Mountpoint: s.mountpoint("app")}
	addMountRef(&meta, daemonManagedMountID)
	runtimeMeta, opts, err := s.requestMetadata(meta, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if runtimeMeta.Options.Mode != "shared" || runtimeMeta.Options.Write != "multi" || runtimeMeta.Options.Engine != "sqlite" || runtimeMeta.Options.Crypt || opts.Flush {
		t.Fatalf("unexpected managed runtime options: meta=%#v opts=%#v", runtimeMeta.Options, opts)
	}
}

func TestCreatePreservesManagedMountRef(t *testing.T) {
	s := newTestDaemon(t)
	meta := managedTestVolume(s, "app")
	if err := s.store.Upsert(meta); err != nil {
		t.Fatal(err)
	}

	w := httptest.NewRecorder()
	s.create(w, httptest.NewRequest(http.MethodPost, "/v1/create", bytes.NewBufferString(`{"name":"app","opts":{"cs.crypt":"false"}}`)))
	assertDaemonOK(t, w)

	got, ok := s.store.Get("app")
	if !ok {
		t.Fatal("volume missing after create")
	}
	if !got.MountIDs[daemonManagedMountID] {
		t.Fatalf("managed mount ref was not preserved: %#v", got.MountIDs)
	}
}

func TestCreatePersistsNonDestructiveOptions(t *testing.T) {
	s := newTestDaemon(t)

	w := httptest.NewRecorder()
	s.create(w, httptest.NewRequest(http.MethodPost, "/v1/create", bytes.NewBufferString(`{"name":"app","opts":{"cs.mode":"shared","cs.write":"single","cs.engine":"auto","cs.crypt":"false","cs.backup":"false"}}`)))
	assertDaemonOK(t, w)

	got, ok := s.store.Get("app")
	if !ok {
		t.Fatal("volume missing after create")
	}
	if got.Options.Mode != "shared" || got.Options.Write != "single" || got.Options.Engine != "auto" || got.Options.Crypt || got.Options.Backup {
		t.Fatalf("unexpected stored options: %#v", got.Options)
	}
	if got.Options.Flush {
		t.Fatalf("flush must remain a one-shot command, not persisted: %#v", got.Options)
	}
}

func TestRequestMetadataFallsBackToPersistedOptions(t *testing.T) {
	s := newTestDaemon(t)
	meta := volume.Metadata{
		Name:       "app",
		Mountpoint: s.mountpoint("app"),
		Options: volume.Options{
			Mode:   "shared",
			Write:  "single",
			Engine: "auto",
			Crypt:  false,
			Backup: false,
			Flush:  true,
		},
	}

	runtimeMeta, opts, err := s.requestMetadata(meta, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if runtimeMeta.Options.Mode != "shared" || runtimeMeta.Options.Write != "single" || runtimeMeta.Options.Engine != "auto" || runtimeMeta.Options.Crypt || opts.Crypt {
		t.Fatalf("did not use persisted options: meta=%#v opts=%#v", runtimeMeta.Options, opts)
	}
	if runtimeMeta.Options.Flush || opts.Flush {
		t.Fatalf("persisted fallback must not reapply flush: meta=%#v opts=%#v", runtimeMeta.Options, opts)
	}
}

func TestRemoveRetainsManagedVolumeWithoutFlush(t *testing.T) {
	s := newTestDaemon(t)
	meta := managedTestVolume(s, "app")
	meta.Options.Flush = true
	if err := s.store.Upsert(meta); err != nil {
		t.Fatal(err)
	}

	w := httptest.NewRecorder()
	s.remove(w, httptest.NewRequest(http.MethodPost, "/v1/remove", bytes.NewBufferString(`{"name":"app","id":"docker-id"}`)))
	assertDaemonOK(t, w)

	got, ok := s.store.Get("app")
	if !ok {
		t.Fatal("managed volume should be retained without flush")
	}
	if !got.MountIDs[daemonManagedMountID] {
		t.Fatalf("managed mount ref missing after remove: %#v", got.MountIDs)
	}
}

func TestRemoveManagedVolumeWithFlushDeletesMetadata(t *testing.T) {
	s := newTestDaemon(t)
	meta := managedTestVolume(s, "app")
	if err := s.store.Upsert(meta); err != nil {
		t.Fatal(err)
	}

	w := httptest.NewRecorder()
	s.remove(w, httptest.NewRequest(http.MethodPost, "/v1/remove", bytes.NewBufferString(`{"name":"app","opts":{"flush":"true"}}`)))
	assertDaemonOK(t, w)

	if _, ok := s.store.Get("app"); ok {
		t.Fatal("managed volume should be deleted when flush=true is explicit")
	}
}

func newTestDaemon(t *testing.T) *Server {
	t.Helper()
	root := t.TempDir()
	s, err := New(Config{RootDir: root, StatePath: filepath.Join(root, ".state", "volumes.json")})
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func managedTestVolume(s *Server, name string) volume.Metadata {
	meta := volume.Metadata{
		Name:       name,
		Mountpoint: s.mountpoint(name),
		Options: volume.Options{
			Mode:   "private",
			Write:  "single",
			Engine: "auto",
			Crypt:  false,
			Backup: false,
		},
	}
	addMountRef(&meta, daemonManagedMountID)
	return meta
}

func assertDaemonOK(t *testing.T, w *httptest.ResponseRecorder) {
	t.Helper()
	var resp VolumeResponse
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatal(err)
	}
	if resp.Error != "" {
		t.Fatalf("daemon error: %s", resp.Error)
	}
}
