package gateway

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"cs-storage/internal/auth"
)

func TestProxyForcesJWTSandboxPath(t *testing.T) {
	var gotPath string
	var gotAuth string
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotAuth = r.Header.Get("Authorization")
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer backend.Close()

	srv, err := New(Config{
		Secret:            "secret",
		BackendURL:        backend.URL + "/dav",
		BackendAuthHeader: "Basic backend-secret",
		SandboxPrefix:     "/nodes",
	})
	if err != nil {
		t.Fatal(err)
	}
	token, err := auth.IssueToken("secret", auth.Claims{
		NodeID:     "node-a",
		Sandbox:    "/nodes/node-a",
		Expiration: time.Now().Add(time.Hour).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodPut, "/nodes/node-b/evil.db", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	srv.Routes().ServeHTTP(w, req)
	if w.Code != http.StatusNoContent {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	wantPath := "/dav/nodes/node-a/nodes/node-b/evil.db"
	if gotPath != wantPath {
		t.Fatalf("backend path mismatch: got %q want %q", gotPath, wantPath)
	}
	if gotAuth != "Basic backend-secret" {
		t.Fatalf("backend auth mismatch: got %q", gotAuth)
	}
}

func TestProxyRejectsMissingJWT(t *testing.T) {
	backend := httptest.NewServer(http.NotFoundHandler())
	defer backend.Close()
	srv, err := New(Config{Secret: "secret", BackendURL: backend.URL})
	if err != nil {
		t.Fatal(err)
	}
	w := httptest.NewRecorder()
	srv.Routes().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/file", nil))
	if w.Code != http.StatusForbidden {
		t.Fatalf("status=%d", w.Code)
	}
}

func TestProxyRewritesWebDAVHrefsToGatewayRoot(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", `application/xml; charset="utf-8"`)
		w.WriteHeader(http.StatusMultiStatus)
		_, _ = io.WriteString(w, `<?xml version="1.0"?><D:multistatus xmlns:D="DAV:"><D:response><D:href>/dav/nodes/node-a/</D:href></D:response><D:response><D:href>/dav/nodes/node-a/file.txt</D:href></D:response></D:multistatus>`)
	}))
	defer backend.Close()

	srv, err := New(Config{
		Secret:            "secret",
		BackendURL:        backend.URL + "/dav",
		BackendAuthHeader: "Basic backend-secret",
		SandboxPrefix:     "/nodes",
	})
	if err != nil {
		t.Fatal(err)
	}
	token, err := auth.IssueToken("secret", auth.Claims{
		NodeID:     "node-a",
		Sandbox:    "/nodes/node-a",
		Expiration: time.Now().Add(time.Hour).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest("PROPFIND", "/", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	srv.Routes().ServeHTTP(w, req)
	if w.Code != http.StatusMultiStatus {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	body := w.Body.String()
	if !strings.Contains(body, "<D:href>/</D:href>") || !strings.Contains(body, "<D:href>/file.txt</D:href>") {
		t.Fatalf("hrefs were not rewritten to gateway root: %s", body)
	}
	if strings.Contains(body, "/dav/nodes/node-a") {
		t.Fatalf("backend prefix leaked into response: %s", body)
	}
}
