package gateway

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"cs-storage/internal/auth"
)

func TestBackendBasicAuthHeaderFromUserPassword(t *testing.T) {
	s, err := New(Config{BackendURL: "https://example.test/dav", BackendUser: "user", BackendPassword: "pass"})
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest(http.MethodGet, "http://gateway/file.txt", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("X-CS-Sandbox", "/nodes/node-a")
	req.Header.Set("Accept-Encoding", "gzip")
	s.direct(req)
	if got := req.Header.Get("Authorization"); got != "Basic dXNlcjpwYXNz" {
		t.Fatalf("unexpected backend auth header %q", got)
	}
	if got := req.URL.Path; got != "/dav/nodes/node-a/file.txt" {
		t.Fatalf("unexpected rewritten path %q", got)
	}
	if got := req.Header.Get("Accept-Encoding"); got != "" {
		t.Fatalf("accept-encoding should be stripped before proxying, got %q", got)
	}
}

func TestDirectPreservesCollectionTrailingSlash(t *testing.T) {
	s, err := New(Config{BackendURL: "https://example.test/dav"})
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest("PROPFIND", "http://gateway/", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("X-CS-Sandbox", "/nodes/node-a")
	s.direct(req)
	if got := req.URL.Path; got != "/dav/nodes/node-a/" {
		t.Fatalf("unexpected rewritten path %q", got)
	}
}

func TestAuthResponseIncludesConfiguredPublicEndpoint(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "MKCOL" {
			t.Fatalf("unexpected backend method %s", r.Method)
		}
		w.WriteHeader(http.StatusMethodNotAllowed)
	}))
	defer backend.Close()

	s, err := New(Config{Secret: "secret", BackendURL: backend.URL + "/dav", PublicURL: "https://storage.example.test/gateway/"})
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Now().Unix()
	body, _ := json.Marshal(map[string]any{
		"node_id":   "node-a",
		"timestamp": ts,
		"signature": auth.SignNodeAuth("secret", "node-a", ts),
	})
	w := httptest.NewRecorder()
	s.Routes().ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/auth", bytes.NewReader(body)))
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var got map[string]any
	if err := json.NewDecoder(w.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got["endpoint"] != "https://storage.example.test/gateway" {
		t.Fatalf("endpoint=%#v", got["endpoint"])
	}
}

func TestAuthResponseInfersEndpointFromForwardedHeaders(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "MKCOL" {
			t.Fatalf("unexpected backend method %s", r.Method)
		}
		w.WriteHeader(http.StatusMethodNotAllowed)
	}))
	defer backend.Close()

	s, err := New(Config{Secret: "secret", BackendURL: backend.URL + "/dav"})
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Now().Unix()
	body, _ := json.Marshal(map[string]any{
		"node_id":   "node-a",
		"timestamp": ts,
		"signature": auth.SignNodeAuth("secret", "node-a", ts),
	})
	req := httptest.NewRequest(http.MethodPost, "/auth", bytes.NewReader(body))
	req.Header.Set("X-Forwarded-Proto", "https")
	req.Header.Set("X-Forwarded-Host", "storage.example.test")
	w := httptest.NewRecorder()
	s.Routes().ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var got map[string]any
	if err := json.NewDecoder(w.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got["endpoint"] != "https://storage.example.test" {
		t.Fatalf("endpoint=%#v", got["endpoint"])
	}
}

func TestAuthEnsuresBackendSandboxCollections(t *testing.T) {
	var got []string
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		if r.Method != "MKCOL" {
			t.Fatalf("unexpected backend method %s", r.Method)
		}
		got = append(got, r.URL.Path+" "+r.Header.Get("Authorization"))
		w.WriteHeader(http.StatusCreated)
	}))
	defer backend.Close()

	s, err := New(Config{
		Secret:            "secret",
		BackendURL:        backend.URL + "/dav",
		BackendAuthHeader: "Basic backend-secret",
		SandboxPrefix:     "/nodes",
	})
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Now().Unix()
	body, _ := json.Marshal(map[string]any{
		"node_id":   "node-a",
		"timestamp": ts,
		"signature": auth.SignNodeAuth("secret", "node-a", ts),
	})
	w := httptest.NewRecorder()
	s.Routes().ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/auth", bytes.NewReader(body)))
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	want := []string{
		"/dav/nodes Basic backend-secret",
		"/dav/nodes/node-a Basic backend-secret",
	}
	if len(got) != len(want) {
		t.Fatalf("backend calls=%#v want %#v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("backend call %d=%q want %q", i, got[i], want[i])
		}
	}
}

func TestAuthAcceptsRedirectForExistingBackendCollection(t *testing.T) {
	var got []string
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.Method+" "+r.URL.Path)
		switch r.Method {
		case "MKCOL":
			http.Redirect(w, r, r.URL.Path+"/", http.StatusMovedPermanently)
		case "PROPFIND":
			if r.Header.Get("Depth") != "0" {
				t.Fatalf("unexpected PROPFIND depth %q", r.Header.Get("Depth"))
			}
			w.WriteHeader(http.StatusMultiStatus)
		default:
			t.Fatalf("unexpected backend method %s", r.Method)
		}
	}))
	defer backend.Close()

	s, err := New(Config{Secret: "secret", BackendURL: backend.URL + "/dav", SandboxPrefix: "/nodes"})
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Now().Unix()
	body, _ := json.Marshal(map[string]any{
		"node_id":   "node-a",
		"timestamp": ts,
		"signature": auth.SignNodeAuth("secret", "node-a", ts),
	})
	w := httptest.NewRecorder()
	s.Routes().ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/auth", bytes.NewReader(body)))
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	want := []string{
		"MKCOL /dav/nodes",
		"PROPFIND /dav/nodes/",
		"MKCOL /dav/nodes/node-a",
		"PROPFIND /dav/nodes/node-a/",
	}
	if len(got) != len(want) {
		t.Fatalf("backend calls=%#v want %#v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("backend call %d=%q want %q", i, got[i], want[i])
		}
	}
}

func TestAuthFailsWhenBackendSandboxCannotBeCreated(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer backend.Close()

	s, err := New(Config{Secret: "secret", BackendURL: backend.URL + "/dav"})
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Now().Unix()
	body, _ := json.Marshal(map[string]any{
		"node_id":   "node-a",
		"timestamp": ts,
		"signature": auth.SignNodeAuth("secret", "node-a", ts),
	})
	w := httptest.NewRecorder()
	s.Routes().ServeHTTP(w, httptest.NewRequest(http.MethodPost, "/auth", bytes.NewReader(body)))
	if w.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
}
