package daemon

import (
	"bytes"
	"context"
	"cs-storage/internal/volume"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestForgetRootSendsEmptyPayload(t *testing.T) {
	var payload map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/vfs/forget" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
	}))
	defer srv.Close()

	rc := RcloneRC{Addr: srv.URL}
	if err := rc.Forget(context.Background(), "/"); err != nil {
		t.Fatal(err)
	}
	if len(payload) != 0 {
		t.Fatalf("expected empty payload for root forget, got %#v", payload)
	}
}

func TestForgetRcloneVFSRunsForRealtimeMounts(t *testing.T) {
	calls := 0
	var payload map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path != "/vfs/forget" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		user, pass, ok := r.BasicAuth()
		if !ok || user != "u" || pass != "p" {
			t.Fatalf("missing rc basic auth: ok=%v user=%q pass=%q", ok, user, pass)
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
	}))
	defer srv.Close()

	s := &Server{cfg: Config{RcloneRCAddr: srv.URL, RcloneRCUser: "u", RcloneRCPassword: "p"}}
	meta := volume.Metadata{Options: volume.Options{Mode: "private", Write: "single", Engine: "auto", Crypt: false}}
	if err := s.forgetRcloneVFS(context.Background(), meta); err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatalf("expected one forget call, got %d", calls)
	}
	if len(payload) != 0 {
		t.Fatalf("expected root forget payload, got %#v", payload)
	}
}

func TestForgetRcloneVFSSkipsSharedMultiMounts(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
	}))
	defer srv.Close()

	s := &Server{cfg: Config{RcloneRCAddr: srv.URL}}
	meta := volume.Metadata{Options: volume.Options{Mode: "shared", Write: "multi", Engine: "static", Crypt: false}}
	if err := s.forgetRcloneVFS(context.Background(), meta); err != nil {
		t.Fatal(err)
	}
	if calls != 0 {
		t.Fatalf("shared multi mounts must not call rclone vfs/forget, got %d calls", calls)
	}
}

func TestMountForRealtimeVolumeForgetsRcloneVFSBeforeReturning(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path != "/vfs/forget" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		var payload map[string]string
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		if len(payload) != 0 {
			t.Fatalf("expected root forget payload, got %#v", payload)
		}
	}))
	defer srv.Close()

	oldIsMountpoint := isMountpointFunc
	isMountpointFunc = func(string) bool { return true }
	t.Cleanup(func() { isMountpointFunc = oldIsMountpoint })

	s := newTestDaemon(t)
	s.cfg.ServerURL = "http://127.0.0.1"
	s.cfg.NodeID = "node-a"
	s.cfg.NodeSecret = "secret"
	s.cfg.RcloneRCAddr = srv.URL
	if err := s.store.Upsert(volume.Metadata{Name: "vol", Mountpoint: s.mountpoint("vol")}); err != nil {
		t.Fatal(err)
	}

	w := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/v1/mount", bytes.NewBufferString(`{"name":"vol","id":"docker-mount","opts":{"cs.crypt":"false"}}`))
	s.mount(w, req)
	assertDaemonOK(t, w)

	if calls != 1 {
		t.Fatalf("expected Docker Mount to forget rclone VFS once, got %d calls", calls)
	}
	got, ok := s.store.Get("vol")
	if !ok || !got.MountIDs["docker-mount"] {
		t.Fatalf("mount ref missing after successful mount: ok=%v meta=%#v", ok, got)
	}
}
