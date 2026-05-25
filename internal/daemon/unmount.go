package daemon

import (
	"fmt"
	"os/exec"
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
		if err == nil || !isMountpointFunc(path) {
			return nil
		}
		last = fmt.Errorf("%s failed: %w: %s", parts[0], err, string(out))
	}
	if last != nil {
		return last
	}
	return nil
}
