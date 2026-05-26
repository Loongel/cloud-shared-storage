package plugin

import (
	"bytes"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"cs-storage/internal/daemon"
)

func TestPluginProxiesVolumeLifecycleToDaemon(t *testing.T) {
	dir := t.TempDir()
	daemonSocket := filepath.Join(dir, "daemon.sock")
	d, err := daemon.New(daemon.Config{
		SocketPath: daemonSocket,
		RootDir:    filepath.Join(dir, "vols"),
		StatePath:  filepath.Join(dir, "state", "volumes.json"),
	})
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = d.ListenAndServe() }()
	waitUnixSocket(t, daemonSocket)

	p := New(Config{DaemonUDS: daemonSocket, Timeout: 2 * time.Second})
	create := postDocker(t, p, "/VolumeDriver.Create", DockerRequest{Name: "vol1", Opts: map[string]string{"cs.crypt": "false"}})
	if create.Err != "" {
		t.Fatalf("create error: %s", create.Err)
	}
	path := postDocker(t, p, "/VolumeDriver.Path", DockerRequest{Name: "vol1"})
	if path.Err != "" {
		t.Fatalf("path error: %s", path.Err)
	}
	if path.Mountpoint == "" {
		t.Fatal("expected mountpoint")
	}
	list := postDocker(t, p, "/VolumeDriver.List", DockerRequest{})
	if list.Err != "" {
		t.Fatalf("list error: %s", list.Err)
	}
	if len(list.Volumes) != 1 || list.Volumes[0].Name != "vol1" {
		t.Fatalf("unexpected list response: %#v", list.Volumes)
	}
	bad := postDocker(t, p, "/VolumeDriver.Create", DockerRequest{Name: "bad", Labels: map[string]string{"flush": "true"}})
	if bad.Err == "" || !strings.Contains(bad.Err, "flush") {
		t.Fatalf("expected flush label rejection, got: %q", bad.Err)
	}

	remove := postDocker(t, p, "/VolumeDriver.Remove", DockerRequest{Name: "vol1"})
	if remove.Err != "" {
		t.Fatalf("remove error: %s", remove.Err)
	}
}

func TestPluginCachesCreateOptionsForLaterCallbacks(t *testing.T) {
	p := New(Config{DaemonUDS: filepath.Join(t.TempDir(), "missing.sock"), DockerSocket: "", Timeout: time.Second})
	p.volumeMu.Lock()
	p.volumes["managed"] = dockerVolumeConfig{Options: runtimeVolumeOptions(map[string]string{"cs.mode": "shared", "cs.write": "multi", "cs.engine": "sqlite", "cs.crypt": "false", "flush": "true"})}
	p.volumeMu.Unlock()

	opts, labels := p.configForRequest(nil, "managed", nil, nil)
	if labels != nil {
		t.Fatalf("expected no labels, got %#v", labels)
	}
	if opts["cs.mode"] != "shared" || opts["cs.write"] != "multi" || opts["cs.engine"] != "sqlite" || opts["cs.crypt"] != "false" {
		t.Fatalf("cached opts not returned: %#v", opts)
	}
	if _, ok := opts["flush"]; ok {
		t.Fatalf("flush must not be cached for later callbacks: %#v", opts)
	}
}

func TestPluginReturnsDaemonUnavailable(t *testing.T) {
	dir := t.TempDir()
	missingSocket := filepath.Join(dir, "missing-daemon.sock")
	p := New(Config{DaemonUDS: missingSocket, Timeout: 100 * time.Millisecond})

	start := time.Now()
	create := postDocker(t, p, "/VolumeDriver.Create", DockerRequest{Name: "vol1", Opts: map[string]string{"cs.crypt": "false"}})
	if create.Err == "" {
		t.Fatal("expected daemon unavailable error")
	}
	if !strings.Contains(create.Err, "daemon unavailable") {
		t.Fatalf("expected daemon unavailable error, got: %q", create.Err)
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("daemon unavailable response was too slow: %s", elapsed)
	}
}

func postDocker(t *testing.T, s *Server, path string, req DockerRequest) dockerResponse {
	t.Helper()
	b, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	s.routes().ServeHTTP(w, httptest.NewRequest(http.MethodPost, path, bytes.NewReader(b)))
	var out dockerResponse
	if err := json.NewDecoder(w.Body).Decode(&out); err != nil {
		t.Fatalf("decode response: %v; body=%s", err, w.Body.String())
	}
	return out
}

func waitUnixSocket(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			conn, err := net.DialTimeout("unix", path, 100*time.Millisecond)
			if err == nil {
				_ = conn.Close()
				return
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("unix socket did not become ready: %s", path)
}
