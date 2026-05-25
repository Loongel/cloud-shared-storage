package daemon

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCreateTemporarilyUnlocksAndRelocksRoot(t *testing.T) {
	logPath := installFakeChattr(t)
	root := t.TempDir()
	srv, err := New(Config{RootDir: root, StatePath: filepath.Join(root, ".state", "volumes.json"), EnableChattr: true})
	if err != nil {
		t.Fatal(err)
	}

	body := bytes.NewBufferString(`{"name":"vol","opts":{"cs.crypt":"false"}}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/create", body)
	w := httptest.NewRecorder()
	srv.create(w, req)
	assertNoDaemonError(t, w.Body.Bytes())

	if _, err := os.Stat(filepath.Join(root, "vol", "mount")); err != nil {
		t.Fatalf("mountpoint was not created: %v", err)
	}
	want := "-i " + root + "\n+i " + root + "\n"
	if got := readFile(t, logPath); got != want {
		t.Fatalf("unexpected chattr calls:\ngot:\n%swant:\n%s", got, want)
	}
}

func TestCreateRelocksRootAfterFailure(t *testing.T) {
	logPath := installFakeChattr(t)
	root := t.TempDir()
	badStateParent := filepath.Join(root, "state-file")
	srv, err := New(Config{RootDir: root, StatePath: filepath.Join(badStateParent, "volumes.json"), EnableChattr: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(badStateParent, []byte("not a dir"), 0o600); err != nil {
		t.Fatal(err)
	}

	body := bytes.NewBufferString(`{"name":"vol","opts":{"cs.crypt":"false"}}`)
	req := httptest.NewRequest(http.MethodPost, "/v1/create", body)
	w := httptest.NewRecorder()
	srv.create(w, req)
	if !strings.Contains(w.Body.String(), "not a directory") {
		t.Fatalf("expected create failure, got body %s", w.Body.String())
	}

	want := "-i " + root + "\n+i " + root + "\n"
	if got := readFile(t, logPath); got != want {
		t.Fatalf("root guard was not restored after failure:\ngot:\n%swant:\n%s", got, want)
	}
}

func installFakeChattr(t *testing.T) string {
	t.Helper()
	binDir := t.TempDir()
	logPath := filepath.Join(t.TempDir(), "chattr.log")
	fake := filepath.Join(binDir, "chattr")
	script := "#!/bin/sh\nprintf '%s %s\\n' \"$1\" \"$2\" >> \"$CS_CHATTR_LOG\"\n"
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("CS_CHATTR_LOG", logPath)
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return logPath
}

func assertNoDaemonError(t *testing.T, body []byte) {
	t.Helper()
	var resp VolumeResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("invalid response json %q: %v", string(body), err)
	}
	if resp.Error != "" {
		t.Fatalf("daemon returned error: %s", resp.Error)
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
