package daemon

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"cs-storage/internal/volume"
)

func TestDaemonMetrics(t *testing.T) {
	dir := t.TempDir()
	s, err := New(Config{RootDir: dir, StatePath: dir + "/state/volumes.json"})
	if err != nil {
		t.Fatal(err)
	}
	s.procs.stats = ProcessStats{Starts: 3, Exits: 2, RestartAttempts: 4, RestartSuccesses: 1, RestartFailures: 3}
	s.procs.desired["missing"] = true
	if err := s.store.Upsert(volume.Metadata{
		Name:       "vol1",
		Mountpoint: dir + "/vol1/mount",
		Options:    volume.Options{Mode: "shared", Write: "multi", Engine: "auto", Backup: true},
		MountIDs:   map[string]bool{"a": true, "b": true},
	}); err != nil {
		t.Fatal(err)
	}
	if err := s.store.Upsert(volume.Metadata{
		Name:       "vol2",
		Mountpoint: dir + "/vol2/mount",
		Options:    volume.Options{Mode: "private", Write: "single", Engine: "auto"},
	}); err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	s.routes().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	metrics := w.Body.String()
	for _, want := range []string{
		"cs_daemon_volumes_total 2",
		"cs_daemon_mounted_volumes_total 1",
		"cs_daemon_mount_refs_total 2",
		"cs_daemon_managed_processes_total 0",
		"cs_daemon_desired_processes_total 1",
		"cs_daemon_unhealthy_processes_total 1",
		"cs_daemon_process_starts_total 3",
		"cs_daemon_process_exits_total 2",
		"cs_daemon_process_restart_attempts_total 4",
		"cs_daemon_process_restart_successes_total 1",
		"cs_daemon_process_restart_failures_total 3",
		"cs_daemon_shared_multi_volumes_total 0",
		"cs_daemon_backup_enabled_volumes_total 0",
	} {
		if !strings.Contains(metrics, want) {
			t.Fatalf("metrics missing %q:\n%s", want, metrics)
		}
	}
}

func TestDaemonReadyzReflectsDesiredProcesses(t *testing.T) {
	dir := t.TempDir()
	s, err := New(Config{RootDir: dir, StatePath: dir + "/state/volumes.json"})
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	s.routes().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if w.Code != http.StatusNoContent {
		t.Fatalf("expected ready daemon, got %d %q", w.Code, w.Body.String())
	}
	s.procs.desired["missing"] = true
	w = httptest.NewRecorder()
	s.routes().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if w.Code != http.StatusServiceUnavailable || !strings.Contains(w.Body.String(), "unhealthy managed processes: 1") {
		t.Fatalf("expected unready daemon, got %d %q", w.Code, w.Body.String())
	}
}
