package gateway

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"cs-storage/internal/auth"
)

func TestKVPersistence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "kv.json")
	s, err := New(Config{Secret: "secret", BackendURL: "https://example.test", KVPath: path})
	if err != nil {
		t.Fatal(err)
	}
	token, err := auth.IssueToken("secret", auth.Claims{NodeID: "node-a", Sandbox: "/nodes/node-a", Expiration: time.Now().Add(time.Hour).Unix()})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPut, "/v1/kv/leader", bytes.NewBufferString("node-a"))
	req.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	s.kvHTTP(w, req)
	if w.Code != http.StatusNoContent {
		t.Fatalf("put status = %d body=%s", w.Code, w.Body.String())
	}
	reloaded, err := New(Config{Secret: "secret", BackendURL: "https://example.test", KVPath: path})
	if err != nil {
		t.Fatal(err)
	}
	if got := string(reloaded.kv["leader"]); got != "node-a" {
		t.Fatalf("persisted value mismatch: %q", got)
	}
}
