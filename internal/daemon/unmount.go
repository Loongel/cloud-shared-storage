package daemon

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

func unmountPath(path string) error {
	if path == "" || !isMountpointFunc(path) {
		return nil
	}
	commands := [][]string{
		{"fusermount3", "-u", path},
		{"fusermount", "-u", path},
		{"umount", path},
	}
	var last error
	for _, parts := range commands {
		bin, err := exec.LookPath(parts[0])
		if err != nil {
			last = err
			continue
		}
		cmd := exec.Command(bin, parts[1:]...)
		out, err := cmd.CombinedOutput()
		if err == nil || !isMountpointFunc(path) || isUnmountedOutput(out) {
			return nil
		}
		last = fmt.Errorf("%s failed: %w: %s", parts[0], err, string(out))
	}
	if last != nil {
		return last
	}
	return nil
}

func isUnmountedOutput(out []byte) bool {
	text := strings.ToLower(string(out))
	return strings.Contains(text, "not mounted") ||
		strings.Contains(text, "not a mountpoint") ||
		strings.Contains(text, "no mount point specified") ||
		strings.Contains(text, "mountpoint is not mounted")
}

func cleanupVolumeRoot(layout Layout) error {
	if layout.Root == "" {
		return nil
	}
	if err := unmountVolumeMountpoints(layout); err != nil {
		return err
	}
	var last error
	for i := 0; i < 4; i++ {
		if err := os.RemoveAll(layout.Root); err == nil {
			return nil
		} else {
			last = err
		}
		_ = unmountVolumeMountpoints(layout)
		time.Sleep(time.Duration(i+1) * 200 * time.Millisecond)
	}
	return last
}

func unmountVolumeMountpoints(layout Layout) error {
	paths := []string{
		layout.Mountpoint,
		layout.LiteFSMount,
		layout.Gluster,
		layout.Cache,
		layout.Remote,
		layout.Cipher,
		layout.LocalDisk,
	}
	if layout.Root != "" {
		_ = filepath.WalkDir(layout.Root, func(path string, d os.DirEntry, err error) error {
			if err == nil && d != nil && d.IsDir() && isMountpointFunc(path) {
				paths = append(paths, path)
			}
			return nil
		})
	}
	paths = uniqueNonEmpty(paths)
	sort.Slice(paths, func(i, j int) bool {
		return len(paths[i]) > len(paths[j])
	})
	for _, path := range paths {
		if err := unmountPath(path); err != nil {
			return err
		}
	}
	return nil
}

func uniqueNonEmpty(values []string) []string {
	seen := map[string]bool{}
	out := make([]string, 0, len(values))
	for _, value := range values {
		if value == "" || seen[value] {
			continue
		}
		seen[value] = true
		out = append(out, value)
	}
	return out
}
