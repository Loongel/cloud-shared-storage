package daemon

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestProcessManagerTracksRunningAndExit(t *testing.T) {
	bin := writeScript(t, "slow.sh", "#!/bin/sh\nsleep 5\n")
	m := NewProcessManager()
	if err := m.Start(ProcessSpec{Key: "slow", Binary: bin}); err != nil {
		t.Fatal(err)
	}
	if !m.IsRunning("slow") {
		t.Fatal("process should be tracked as running")
	}
	if err := m.Stop("slow"); err != nil {
		t.Fatal(err)
	}
	if m.IsRunning("slow") || m.Count() != 0 {
		t.Fatalf("process should be stopped, running=%v count=%d", m.IsRunning("slow"), m.Count())
	}
}

func TestProcessManagerWritesLogAndReleasesExitedProcess(t *testing.T) {
	bin := writeScript(t, "write-log.sh", "#!/bin/sh\nprintf process-log\n")
	logPath := filepath.Join(t.TempDir(), "proc.log")
	m := NewProcessManager()
	if err := m.Start(ProcessSpec{Key: "log", Binary: bin, LogPath: logPath}); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, time.Second, func() bool { return !m.IsRunning("log") })
	b, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(b)) != "process-log" {
		t.Fatalf("unexpected process log %q", b)
	}
}

func TestProcessManagerInitialStartFailureDoesNotLeaveDesiredProcess(t *testing.T) {
	m := NewProcessManager()
	err := m.Start(ProcessSpec{Key: "missing", Binary: filepath.Join(t.TempDir(), "missing"), Restart: true})
	if err == nil {
		t.Fatal("expected missing binary error")
	}
	if m.DesiredCount() != 0 || m.UnhealthyCount() != 0 {
		t.Fatalf("initial start failure should not leave desired state, desired=%d unhealthy=%d", m.DesiredCount(), m.UnhealthyCount())
	}
}

func TestProcessManagerRestartsUnexpectedExit(t *testing.T) {
	counter := filepath.Join(t.TempDir(), "count")
	body := strings.ReplaceAll(`#!/bin/sh
count='__COUNTER__'
n=0
if [ -f "$count" ]; then n=$(cat "$count"); fi
n=$((n+1))
printf %s "$n" > "$count"
if [ "$n" -lt 2 ]; then exit 0; fi
sleep 5
`, "__COUNTER__", counter)
	bin := writeScript(t, "restart.sh", body)
	m := NewProcessManager()
	if err := m.Start(ProcessSpec{Key: "restart", Binary: bin, Restart: true, RestartDelay: 10 * time.Millisecond}); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, time.Second, func() bool {
		b, err := os.ReadFile(counter)
		return err == nil && strings.TrimSpace(string(b)) == "2" && m.IsRunning("restart")
	})
	if err := m.Stop("restart"); err != nil {
		t.Fatal(err)
	}
}

func TestProcessManagerRetriesRestartAfterTemporaryStartFailure(t *testing.T) {
	counter := filepath.Join(t.TempDir(), "count")
	dir := t.TempDir()
	bin := filepath.Join(dir, "flaky.sh")
	first := strings.ReplaceAll(`#!/bin/sh
printf 1 > '__COUNTER__'
rm -f "$0"
exit 0
`, "__COUNTER__", counter)
	if err := os.WriteFile(bin, []byte(first), 0o700); err != nil {
		t.Fatal(err)
	}
	m := NewProcessManager()
	if err := m.Start(ProcessSpec{Key: "flaky", Binary: bin, Restart: true, RestartDelay: 10 * time.Millisecond}); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, time.Second, func() bool {
		b, err := os.ReadFile(counter)
		return err == nil && strings.TrimSpace(string(b)) == "1" && !m.IsRunning("flaky")
	})
	time.Sleep(40 * time.Millisecond)
	second := strings.ReplaceAll(`#!/bin/sh
printf 2 > '__COUNTER__'
sleep 5
`, "__COUNTER__", counter)
	if err := os.WriteFile(bin, []byte(second), 0o700); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, time.Second, func() bool {
		b, err := os.ReadFile(counter)
		return err == nil && strings.TrimSpace(string(b)) == "2" && m.IsRunning("flaky")
	})
	stats := m.Stats()
	if stats.Starts < 2 || stats.Exits < 1 || stats.RestartAttempts < 2 || stats.RestartFailures == 0 || stats.RestartSuccesses != 1 {
		t.Fatalf("unexpected restart stats: %#v", stats)
	}
	if err := m.Stop("flaky"); err != nil {
		t.Fatal(err)
	}
}

func TestProcessManagerStopCancelsRestart(t *testing.T) {
	counter := filepath.Join(t.TempDir(), "count")
	body := strings.ReplaceAll(`#!/bin/sh
count='__COUNTER__'
n=0
if [ -f "$count" ]; then n=$(cat "$count"); fi
n=$((n+1))
printf %s "$n" > "$count"
exit 0
`, "__COUNTER__", counter)
	bin := writeScript(t, "stop-no-restart.sh", body)
	m := NewProcessManager()
	if err := m.Start(ProcessSpec{Key: "stop", Binary: bin, Restart: true, RestartDelay: 200 * time.Millisecond}); err != nil {
		t.Fatal(err)
	}
	waitUntil(t, time.Second, func() bool {
		b, err := os.ReadFile(counter)
		return err == nil && strings.TrimSpace(string(b)) == "1" && !m.IsRunning("stop")
	})
	if err := m.Stop("stop"); err != nil {
		t.Fatal(err)
	}
	time.Sleep(300 * time.Millisecond)
	b, err := os.ReadFile(counter)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(b)) != "1" || m.IsRunning("stop") || m.Count() != 0 {
		t.Fatalf("stop should cancel pending restart, count=%q running=%v procs=%d", b, m.IsRunning("stop"), m.Count())
	}
}

func TestWaitForManagedMountpointReportsEarlyExit(t *testing.T) {
	bin := writeScript(t, "exit.sh", "#!/bin/sh\nexit 0\n")
	m := NewProcessManager()
	if err := m.Start(ProcessSpec{Key: "exit", Binary: bin}); err != nil {
		t.Fatal(err)
	}
	err := waitForManagedMountpoint(m, "exit", filepath.Join(t.TempDir(), "mnt"), time.Second)
	if err == nil || !strings.Contains(err.Error(), "exited before mount became ready") {
		t.Fatalf("expected early exit error, got %v", err)
	}
}

func TestWaitForManagedMountpointWaitsForDesiredRestart(t *testing.T) {
	counter := filepath.Join(t.TempDir(), "counter")
	mountpoint := filepath.Join(t.TempDir(), "mnt")
	body := strings.ReplaceAll(`#!/bin/sh
set -eu
n=0
if [ -f "__COUNTER__" ]; then n=$(cat "__COUNTER__"); fi
n=$((n + 1))
echo "$n" > "__COUNTER__"
if [ "$n" -lt 2 ]; then exit 1; fi
mkdir -p "__MOUNTPOINT__"
sleep 2
`, "__COUNTER__", counter)
	body = strings.ReplaceAll(body, "__MOUNTPOINT__", mountpoint)
	bin := writeScript(t, "restart.sh", body)
	oldIsMountpoint := isMountpointFunc
	isMountpointFunc = func(path string) bool {
		if path != mountpoint {
			return false
		}
		_, err := os.Stat(mountpoint)
		return err == nil
	}
	t.Cleanup(func() { isMountpointFunc = oldIsMountpoint })

	m := NewProcessManager()
	if err := m.Start(ProcessSpec{Key: "restart", Binary: bin, Restart: true, RestartDelay: 10 * time.Millisecond}); err != nil {
		t.Fatal(err)
	}
	if err := waitForManagedMountpoint(m, "restart", mountpoint, time.Second); err != nil {
		t.Fatalf("expected restart to become ready, got %v", err)
	}
	_ = m.Stop("restart")
}

func writeScript(t *testing.T, name string, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(body), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

func waitUntil(t *testing.T, timeout time.Duration, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("condition was not met before timeout")
}
