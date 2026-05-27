package daemon

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

func TestAuthClientParsesEndpoint(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/auth" {
			t.Fatalf("unexpected path %s", r.URL.Path)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"token":    "jwt-token",
			"expires":  123,
			"sandbox":  "/nodes/node-a",
			"endpoint": "https://storage.example.test",
		})
	}))
	defer srv.Close()

	tok, err := (AuthClient{ServerURL: srv.URL, NodeID: "node-a", Secret: "secret"}).Token(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if tok.Value != "jwt-token" || tok.Endpoint != "https://storage.example.test" || tok.Sandbox != "/nodes/node-a" {
		t.Fatalf("unexpected token: %#v", tok)
	}
}

func TestAuthClientSendsNamespace(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req map[string]any
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatal(err)
		}
		if req["namespace"] != "shared" {
			t.Fatalf("namespace not sent: %#v", req)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"token": "jwt-token"})
	}))
	defer srv.Close()

	if _, err := (AuthClient{ServerURL: srv.URL, NodeID: "node-a", Secret: "secret", Namespace: "shared"}).Token(context.Background()); err != nil {
		t.Fatal(err)
	}
}

func TestAuthClientRetriesTransientFailures(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) < 3 {
			http.Error(w, "temporary", http.StatusServiceUnavailable)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"token": "jwt-token"})
	}))
	defer srv.Close()

	tok, err := (AuthClient{ServerURL: srv.URL, NodeID: "node-a", Secret: "secret"}).Token(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if tok.Value != "jwt-token" {
		t.Fatalf("unexpected token: %#v", tok)
	}
	if calls.Load() != 3 {
		t.Fatalf("expected 3 auth attempts, got %d", calls.Load())
	}
}
