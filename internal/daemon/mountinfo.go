package daemon

import (
	"fmt"
	"os"
	"strings"
	"time"
)

const defaultMountReadyTimeout = 60 * time.Second

func waitForMountpoint(path string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if isMountpointFunc(path) {
			return true
		}
		time.Sleep(100 * time.Millisecond)
	}
	return false
}

func waitForManagedMountpoint(procs *ProcessManager, key string, path string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if isMountpointFunc(path) {
			return nil
		}
		if procs != nil && !procs.IsRunning(key) {
			if procs.IsDesired(key) {
				time.Sleep(100 * time.Millisecond)
				continue
			}
			return fmt.Errorf("%s exited before mount became ready at %s", key, path)
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("%s mount did not become ready at %s", key, path)
}

var isMountpointFunc = isMountpoint

func isMountpoint(path string) bool {
	b, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return false
	}
	needle := " " + path + " "
	for _, line := range strings.Split(string(b), "\n") {
		if strings.Contains(line, needle) {
			return true
		}
	}
	return false
}
