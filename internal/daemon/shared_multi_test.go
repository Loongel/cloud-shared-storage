package daemon

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"cs-storage/internal/volume"
)

func TestWriteLiteFSConfig(t *testing.T) {
	s := &Server{cfg: Config{RootDir: t.TempDir(), LiteFSHTTPAddr: ":20202", LiteFSLeaseType: "consul", LiteFSAdvertiseURL: "http://node-a:20202", LiteFSConsulURL: "http://server:8080", LiteFSConsulKey: "cs/litefs/vol", LiteFSConsulTTL: "15s", LiteFSConsulLockDelay: "2s", LiteFSHostname: "node-a", LiteFSPromote: true, LiteFSCandidate: true}}
	layout := s.layout("vol")
	path, err := s.writeLiteFSConfig(volume.Metadata{Name: "vol"}, layout.Mountpoint, layout.LiteFSData)
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	text := string(b)
	for _, want := range []string{"fuse:", "data:", "lease:", "candidate: true", "type: \"consul\"", "hostname: \"node-a\"", "promote: true", "consul:", "url: \"http://server:8080\"", "key: \"cs/litefs/vol\"", "ttl: \"15s\"", "lock-delay: \"2s\""} {
		if !strings.Contains(text, want) {
			t.Fatalf("missing %q in config:\n%s", want, text)
		}
	}
}

func TestLiteFSEnvIncludesConsulToken(t *testing.T) {
	s := &Server{cfg: Config{LiteFSConsulToken: "secret-token"}}
	env := s.liteFSEnv()
	if len(env) != 1 || env[0] != "CONSUL_HTTP_TOKEN=secret-token" {
		t.Fatalf("unexpected env: %#v", env)
	}
}

func TestEnsureGlusterRequiresRemote(t *testing.T) {
	s := &Server{cfg: Config{RootDir: t.TempDir()}}
	err := s.ensureGluster(volume.Metadata{Name: "vol"})
	if err == nil || !strings.Contains(err.Error(), "CS_GLUSTER_REMOTE") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestQuoteYAML(t *testing.T) {
	if got := quoteYAML(filepath.Join("/tmp", "a\"b")); got != "\"/tmp/a\\\"b\"" {
		t.Fatalf("unexpected quoted value %s", got)
	}
}
