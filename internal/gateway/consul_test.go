package gateway

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"cs-storage/internal/auth"
)

func TestConsulKVAndSessionCompatibility(t *testing.T) {
	s, err := New(Config{Secret: "secret", BackendURL: "https://example.test"})
	if err != nil {
		t.Fatal(err)
	}
	token, err := auth.IssueToken("secret", auth.Claims{NodeID: "node-a", Sandbox: "/nodes/node-a", Expiration: time.Now().Add(time.Hour).Unix()})
	if err != nil {
		t.Fatal(err)
	}

	put := httptest.NewRequest(http.MethodPut, "/v1/kv/litefs/primary", bytes.NewBufferString("node-a"))
	put.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	s.Routes().ServeHTTP(w, put)
	if w.Code != http.StatusOK || strings.TrimSpace(w.Body.String()) != "true" {
		t.Fatalf("put = %d %q", w.Code, w.Body.String())
	}

	get := httptest.NewRequest(http.MethodGet, "/v1/kv/litefs/primary", nil)
	get.Header.Set("Authorization", "Bearer "+token)
	w = httptest.NewRecorder()
	s.Routes().ServeHTTP(w, get)
	if w.Code != http.StatusOK {
		t.Fatalf("get = %d %q", w.Code, w.Body.String())
	}
	var entries []consulKVEntry
	if err := json.Unmarshal(w.Body.Bytes(), &entries); err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Key != "litefs/primary" {
		t.Fatalf("unexpected kv entries: %+v", entries)
	}
	decoded, err := base64.StdEncoding.DecodeString(entries[0].Value)
	if err != nil {
		t.Fatal(err)
	}
	if string(decoded) != "node-a" {
		t.Fatalf("unexpected kv value %q", decoded)
	}

	raw := httptest.NewRequest(http.MethodGet, "/v1/kv/litefs/primary?raw", nil)
	raw.Header.Set("Authorization", "Bearer "+token)
	w = httptest.NewRecorder()
	s.Routes().ServeHTTP(w, raw)
	if w.Code != http.StatusOK || w.Body.String() != "node-a" {
		t.Fatalf("raw get = %d %q", w.Code, w.Body.String())
	}

	create := httptest.NewRequest(http.MethodPut, "/v1/session/create", bytes.NewBufferString(`{"Name":"litefs","TTL":"15s","LockDelay":"2s"}`))
	create.Header.Set("Authorization", "Bearer "+token)
	w = httptest.NewRecorder()
	s.Routes().ServeHTTP(w, create)
	if w.Code != http.StatusOK {
		t.Fatalf("session create = %d %q", w.Code, w.Body.String())
	}
	var created map[string]string
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil {
		t.Fatal(err)
	}
	if created["ID"] == "" {
		t.Fatalf("missing session id in %q", w.Body.String())
	}

	info := httptest.NewRequest(http.MethodGet, "/v1/session/info/"+created["ID"], nil)
	info.Header.Set("Authorization", "Bearer "+token)
	w = httptest.NewRecorder()
	s.Routes().ServeHTTP(w, info)
	if w.Code != http.StatusOK {
		t.Fatalf("session info = %d %q", w.Code, w.Body.String())
	}
	var sessions []struct {
		ID        string        `json:"ID"`
		LockDelay time.Duration `json:"LockDelay"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &sessions); err != nil {
		t.Fatal(err)
	}
	if len(sessions) != 1 || sessions[0].ID != created["ID"] || sessions[0].LockDelay != 2*time.Second {
		t.Fatalf("unexpected session info: %+v body=%q", sessions, w.Body.String())
	}

	lock := httptest.NewRequest(http.MethodPut, "/v1/kv/litefs/lock?acquire="+created["ID"], bytes.NewBufferString("node-a"))
	lock.Header.Set("Authorization", "Bearer "+token)
	w = httptest.NewRecorder()
	s.Routes().ServeHTTP(w, lock)
	if w.Code != http.StatusOK || strings.TrimSpace(w.Body.String()) != "true" {
		t.Fatalf("acquire = %d %q", w.Code, w.Body.String())
	}

	badLock := httptest.NewRequest(http.MethodPut, "/v1/kv/litefs/lock?acquire=missing", bytes.NewBufferString("node-b"))
	badLock.Header.Set("Authorization", "Bearer "+token)
	w = httptest.NewRecorder()
	s.Routes().ServeHTTP(w, badLock)
	if w.Code != http.StatusOK || strings.TrimSpace(w.Body.String()) != "false" {
		t.Fatalf("bad acquire = %d %q", w.Code, w.Body.String())
	}
}

func TestConsulTokenAndCASCompatibility(t *testing.T) {
	s, err := New(Config{Secret: "secret", BackendURL: "https://example.test", CoordinatorToken: "coord-token"})
	if err != nil {
		t.Fatal(err)
	}

	put := httptest.NewRequest(http.MethodPut, "/v1/kv/litefs/cluster-id?cas=0", bytes.NewBufferString("cluster-a"))
	put.Header.Set("X-Consul-Token", "coord-token")
	w := httptest.NewRecorder()
	s.Routes().ServeHTTP(w, put)
	if w.Code != http.StatusOK || strings.TrimSpace(w.Body.String()) != "true" {
		t.Fatalf("cas create = %d %q", w.Code, w.Body.String())
	}

	dupe := httptest.NewRequest(http.MethodPut, "/v1/kv/litefs/cluster-id?cas=0", bytes.NewBufferString("cluster-b"))
	dupe.Header.Set("X-Consul-Token", "coord-token")
	w = httptest.NewRecorder()
	s.Routes().ServeHTTP(w, dupe)
	if w.Code != http.StatusOK || strings.TrimSpace(w.Body.String()) != "false" {
		t.Fatalf("cas duplicate = %d %q", w.Code, w.Body.String())
	}

	get := httptest.NewRequest(http.MethodGet, "/v1/kv/litefs/cluster-id", nil)
	get.Header.Set("X-Consul-Token", "coord-token")
	w = httptest.NewRecorder()
	s.Routes().ServeHTTP(w, get)
	if w.Code != http.StatusOK || w.Header().Get("X-Consul-Index") == "" {
		t.Fatalf("token get = %d index=%q body=%q", w.Code, w.Header().Get("X-Consul-Index"), w.Body.String())
	}

	missingToken := httptest.NewRequest(http.MethodGet, "/v1/kv/litefs/cluster-id", nil)
	w = httptest.NewRecorder()
	s.Routes().ServeHTTP(w, missingToken)
	if w.Code != http.StatusForbidden {
		t.Fatalf("missing token = %d %q", w.Code, w.Body.String())
	}
}

func TestConsulSessionTTLReleasesLock(t *testing.T) {
	s, err := New(Config{Secret: "secret", BackendURL: "https://example.test"})
	if err != nil {
		t.Fatal(err)
	}
	token, err := auth.IssueToken("secret", auth.Claims{NodeID: "node-a", Sandbox: "/nodes/node-a", Expiration: time.Now().Add(time.Hour).Unix()})
	if err != nil {
		t.Fatal(err)
	}

	s.sessions["expired"] = consulSession{ID: "expired", TTL: "1ms", Created: time.Now().Add(-time.Second)}
	s.kvLocks["litefs/lock"] = "expired"

	lock := httptest.NewRequest(http.MethodPut, "/v1/kv/litefs/lock?acquire=expired", bytes.NewBufferString("node-a"))
	lock.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	s.Routes().ServeHTTP(w, lock)
	if w.Code != http.StatusOK || strings.TrimSpace(w.Body.String()) != "false" {
		t.Fatalf("expired session acquire = %d %q", w.Code, w.Body.String())
	}
	if holder := s.kvLocks["litefs/lock"]; holder != "" {
		t.Fatalf("expired lock was not released: %q", holder)
	}
}
