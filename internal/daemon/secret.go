package daemon

import (
	"os"
	"path/filepath"
)

func writeSecretFile(path, value string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(value), 0o600)
}

func fileExists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}
