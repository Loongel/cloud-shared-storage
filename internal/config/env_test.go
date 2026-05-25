package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestStringReadsFileFallback(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "secret")
	if err := os.WriteFile(path, []byte("from-file\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CS_TEST_SECRET_FILE", path)
	if got := String("CS_TEST_SECRET", "fallback"); got != "from-file" {
		t.Fatalf("expected file-backed secret, got %q", got)
	}
}

func TestStringEnvOverridesFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "secret")
	if err := os.WriteFile(path, []byte("from-file"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CS_TEST_SECRET", "direct")
	t.Setenv("CS_TEST_SECRET_FILE", path)
	if got := String("CS_TEST_SECRET", "fallback"); got != "direct" {
		t.Fatalf("expected direct env to win, got %q", got)
	}
}

func TestBoolAndDurationReadFileFallback(t *testing.T) {
	dir := t.TempDir()
	boolPath := filepath.Join(dir, "bool")
	durationPath := filepath.Join(dir, "duration")
	if err := os.WriteFile(boolPath, []byte("true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(durationPath, []byte("2s\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CS_TEST_BOOL_FILE", boolPath)
	t.Setenv("CS_TEST_DURATION_FILE", durationPath)
	if !Bool("CS_TEST_BOOL", false) {
		t.Fatal("expected bool from file")
	}
	if got := Duration("CS_TEST_DURATION", time.Second); got != 2*time.Second {
		t.Fatalf("expected duration from file, got %s", got)
	}
}
