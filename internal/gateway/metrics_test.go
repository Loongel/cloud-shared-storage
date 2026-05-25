package gateway

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"cs-storage/internal/auth"
)

func TestGatewayMetrics(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer backend.Close()
	srv, err := New(Config{Secret: "secret", BackendURL: backend.URL})
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Now().Unix()
	sig := auth.SignNodeAuth("secret", "node-a", ts)
	body := bytes.NewBufferString(fmt.Sprintf(`{"node_id":"node-a","timestamp":%d,"signature":"%s"}`, ts, sig))
	srv.Routes().ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/auth", body))
	srv.Routes().ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/missing-token", nil))
	srv.Routes().ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/v1/kv/key", nil))
	srv.Routes().ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/v1/kv/", nil))

	w := httptest.NewRecorder()
	srv.Routes().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	metrics := w.Body.String()
	for _, want := range []string{
		"cs_gateway_auth_issued_total 1",
		"cs_gateway_proxy_requests_total 1",
		"cs_gateway_proxy_forbidden_total 1",
		"cs_gateway_kv_requests_total 2",
		"cs_gateway_kv_forbidden_total 1",
		"cs_gateway_kv_invalid_total 1",
	} {
		if !strings.Contains(metrics, want) {
			t.Fatalf("metrics missing %q:\n%s", want, metrics)
		}
	}
}
