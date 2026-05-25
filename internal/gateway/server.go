package gateway

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"cs-storage/internal/auth"
)

type Config struct {
	Addr              string
	Secret            string
	BackendURL        string
	BackendAuthHeader string
	BackendUser       string
	BackendPassword   string
	TokenTTL          time.Duration
	SandboxPrefix     string
	KVPath            string
	CoordinatorToken  string
	PublicURL         string
}

type rewriteContextKey string

const backendPrefixContextKey rewriteContextKey = "backendPrefix"

type Server struct {
	cfg       Config
	backend   *url.URL
	proxy     *httputil.ReverseProxy
	mu        sync.Mutex
	kv        map[string][]byte
	sessions  map[string]consulSession
	kvLocks   map[string]string
	kvIndexes map[string]uint64
	nextIndex uint64
	metrics   gatewayMetrics
}

type gatewayMetrics struct {
	authIssued     atomic.Uint64
	authRejected   atomic.Uint64
	proxyRequests  atomic.Uint64
	proxyForbidden atomic.Uint64
	kvRequests     atomic.Uint64
	kvForbidden    atomic.Uint64
	kvInvalid      atomic.Uint64
}

func New(cfg Config) (*Server, error) {
	u, err := url.Parse(cfg.BackendURL)
	if err != nil {
		return nil, err
	}
	if cfg.TokenTTL == 0 {
		cfg.TokenTTL = 12 * time.Hour
	}
	if cfg.SandboxPrefix == "" {
		cfg.SandboxPrefix = "/nodes"
	}
	if cfg.BackendAuthHeader == "" && cfg.BackendUser != "" {
		raw := cfg.BackendUser + ":" + cfg.BackendPassword
		cfg.BackendAuthHeader = "Basic " + base64.StdEncoding.EncodeToString([]byte(raw))
	}
	s := &Server{cfg: cfg, backend: u, kv: map[string][]byte{}, sessions: map[string]consulSession{}, kvLocks: map[string]string{}, kvIndexes: map[string]uint64{}, nextIndex: 1}
	if cfg.KVPath != "" {
		if err := s.loadKV(); err != nil {
			return nil, err
		}
	}
	s.proxy = &httputil.ReverseProxy{Director: s.direct, ModifyResponse: s.rewriteWebDAVResponse}
	return s, nil
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/metrics", s.metricsHTTP)
	mux.HandleFunc("/auth", s.auth)
	mux.HandleFunc("/v1/session/", s.consulSessionHTTP)
	mux.HandleFunc("/v1/kv/", s.consulKVHTTP)
	mux.HandleFunc("/", s.proxyHTTP)
	return mux
}

func (s *Server) ListenAndServe() error {
	log.Printf("cs-storage server listening on %s, backend=%s", s.cfg.Addr, s.backend.Redacted())
	return http.ListenAndServe(s.cfg.Addr, s.Routes())
}

func (s *Server) auth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req struct {
		NodeID    string `json:"node_id"`
		Timestamp int64  `json:"timestamp"`
		Signature string `json:"signature"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.metrics.authRejected.Add(1)
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}
	if !auth.VerifyNodeAuth(s.cfg.Secret, req.NodeID, req.Timestamp, req.Signature, 5*time.Minute) {
		s.metrics.authRejected.Add(1)
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	claims := auth.Claims{
		NodeID:     req.NodeID,
		Sandbox:    path.Join(s.cfg.SandboxPrefix, req.NodeID),
		Expiration: time.Now().Add(s.cfg.TokenTTL).Unix(),
	}
	if err := s.ensureBackendSandbox(r.Context(), claims.Sandbox); err != nil {
		s.metrics.authRejected.Add(1)
		log.Printf("failed to prepare backend sandbox for node %q: %v", req.NodeID, err)
		http.Error(w, "backend sandbox unavailable", http.StatusBadGateway)
		return
	}
	token, err := auth.IssueToken(s.cfg.Secret, claims)
	if err != nil {
		s.metrics.authRejected.Add(1)
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	s.metrics.authIssued.Add(1)
	writeJSON(w, map[string]any{
		"token":    token,
		"expires":  claims.Expiration,
		"sandbox":  claims.Sandbox,
		"endpoint": s.publicEndpoint(r),
	})
}

func (s *Server) ensureBackendSandbox(ctx context.Context, sandbox string) error {
	rel := strings.Trim(path.Clean("/"+sandbox), "/")
	if rel == "" {
		return nil
	}
	current := strings.TrimRight(s.backend.Path, "/")
	for _, segment := range strings.Split(rel, "/") {
		if segment == "" {
			continue
		}
		if current == "" {
			current = "/" + segment
		} else {
			current = path.Join(current, segment)
		}
		if err := s.mkcolBackendCollection(ctx, current); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) mkcolBackendCollection(ctx context.Context, collectionPath string) error {
	u := *s.backend
	u.Path = collectionPath
	u.RawPath = ""
	req, err := http.NewRequestWithContext(ctx, "MKCOL", u.String(), nil)
	if err != nil {
		return err
	}
	if s.cfg.BackendAuthHeader != "" {
		req.Header.Set("Authorization", s.cfg.BackendAuthHeader)
	}
	client := &http.Client{
		Timeout: 10 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK, http.StatusCreated, http.StatusNoContent, http.StatusMethodNotAllowed:
		return nil
	case http.StatusMovedPermanently, http.StatusFound, http.StatusTemporaryRedirect, http.StatusPermanentRedirect:
		return s.confirmBackendCollection(ctx, collectionPath)
	default:
		return fmt.Errorf("MKCOL %s returned %s", u.Redacted(), resp.Status)
	}
}

func (s *Server) confirmBackendCollection(ctx context.Context, collectionPath string) error {
	u := *s.backend
	u.Path = collectionPath
	if !strings.HasSuffix(u.Path, "/") {
		u.Path += "/"
	}
	u.RawPath = ""
	req, err := http.NewRequestWithContext(ctx, "PROPFIND", u.String(), nil)
	if err != nil {
		return err
	}
	req.Header.Set("Depth", "0")
	if s.cfg.BackendAuthHeader != "" {
		req.Header.Set("Authorization", s.cfg.BackendAuthHeader)
	}
	client := &http.Client{
		Timeout: 10 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK, http.StatusNoContent, http.StatusMultiStatus:
		return nil
	default:
		return fmt.Errorf("PROPFIND %s returned %s", u.Redacted(), resp.Status)
	}
}

func (s *Server) publicEndpoint(r *http.Request) string {
	if s.cfg.PublicURL != "" {
		return strings.TrimRight(s.cfg.PublicURL, "/")
	}
	scheme := r.Header.Get("X-Forwarded-Proto")
	if scheme == "" {
		if r.TLS != nil {
			scheme = "https"
		} else {
			scheme = "http"
		}
	}
	host := r.Header.Get("X-Forwarded-Host")
	if host == "" {
		host = r.Host
	}
	if host == "" {
		return ""
	}
	return scheme + "://" + host
}

func (s *Server) proxyHTTP(w http.ResponseWriter, r *http.Request) {
	s.metrics.proxyRequests.Add(1)
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	claims, err := auth.VerifyToken(s.cfg.Secret, token)
	if err != nil {
		s.metrics.proxyForbidden.Add(1)
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	r.Header.Set("X-CS-Node-ID", claims.NodeID)
	r.Header.Set("X-CS-Sandbox", claims.Sandbox)
	s.proxy.ServeHTTP(w, r)
}

func (s *Server) direct(r *http.Request) {
	sandbox := r.Header.Get("X-CS-Sandbox")
	keepTrailingSlash := strings.HasSuffix(r.URL.Path, "/")
	original := cleanRelative(r.URL.Path)
	backendPrefix := path.Join(s.backend.Path, sandbox)
	r.URL.Scheme = s.backend.Scheme
	r.URL.Host = s.backend.Host
	r.URL.Path = path.Join(backendPrefix, original)
	if (keepTrailingSlash || original == "") && !strings.HasSuffix(r.URL.Path, "/") {
		r.URL.Path += "/"
	}
	r.URL.RawPath = ""
	*r = *r.WithContext(context.WithValue(r.Context(), backendPrefixContextKey, backendPrefix))
	r.Host = s.backend.Host
	r.Header.Del("Authorization")
	r.Header.Del("Accept-Encoding")
	if s.cfg.BackendAuthHeader != "" {
		r.Header.Set("Authorization", s.cfg.BackendAuthHeader)
	}
}

func (s *Server) rewriteWebDAVResponse(resp *http.Response) error {
	backendPrefix, _ := resp.Request.Context().Value(backendPrefixContextKey).(string)
	if backendPrefix == "" {
		return nil
	}
	if loc := resp.Header.Get("Location"); loc != "" {
		resp.Header.Set("Location", rewriteBackendPrefix(loc, s.backend, backendPrefix))
	}
	if resp.StatusCode != http.StatusMultiStatus {
		return nil
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	rewritten := rewriteBackendPrefix(string(body), s.backend, backendPrefix)
	resp.Body = io.NopCloser(strings.NewReader(rewritten))
	resp.ContentLength = int64(len(rewritten))
	resp.Header.Set("Content-Length", strconv.Itoa(len(rewritten)))
	return nil
}

func rewriteBackendPrefix(value string, backend *url.URL, backendPrefix string) string {
	prefixes := []string{backendPrefix}
	if escaped := (&url.URL{Path: backendPrefix}).EscapedPath(); escaped != backendPrefix {
		prefixes = append(prefixes, escaped)
	}
	for _, prefix := range prefixes {
		absolute := backend.Scheme + "://" + backend.Host + prefix
		value = rewritePrefix(value, absolute)
		value = rewritePrefix(value, prefix)
	}
	return value
}

func rewritePrefix(value, prefix string) string {
	if prefix == "" || prefix == "/" {
		return value
	}
	if value == prefix {
		return "/"
	}
	value = strings.ReplaceAll(value, prefix+"/", "/")
	value = strings.ReplaceAll(value, prefix+"<", "/<")
	value = strings.ReplaceAll(value, prefix+"\"", "/\"")
	return value
}

func cleanRelative(p string) string {
	p = path.Clean("/" + p)
	if p == "/" {
		return ""
	}
	return strings.TrimPrefix(p, "/")
}

func (s *Server) metricsHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "# HELP cs_gateway_auth_issued_total JWT tokens issued by the gateway.\n")
	fmt.Fprintf(w, "# TYPE cs_gateway_auth_issued_total counter\n")
	fmt.Fprintf(w, "cs_gateway_auth_issued_total %d\n", s.metrics.authIssued.Load())
	fmt.Fprintf(w, "# HELP cs_gateway_auth_rejected_total Failed auth requests.\n")
	fmt.Fprintf(w, "# TYPE cs_gateway_auth_rejected_total counter\n")
	fmt.Fprintf(w, "cs_gateway_auth_rejected_total %d\n", s.metrics.authRejected.Load())
	fmt.Fprintf(w, "# HELP cs_gateway_proxy_requests_total Gateway proxy requests.\n")
	fmt.Fprintf(w, "# TYPE cs_gateway_proxy_requests_total counter\n")
	fmt.Fprintf(w, "cs_gateway_proxy_requests_total %d\n", s.metrics.proxyRequests.Load())
	fmt.Fprintf(w, "# HELP cs_gateway_proxy_forbidden_total Gateway proxy requests rejected by JWT verification.\n")
	fmt.Fprintf(w, "# TYPE cs_gateway_proxy_forbidden_total counter\n")
	fmt.Fprintf(w, "cs_gateway_proxy_forbidden_total %d\n", s.metrics.proxyForbidden.Load())
	fmt.Fprintf(w, "# HELP cs_gateway_kv_requests_total Gateway KV API requests.\n")
	fmt.Fprintf(w, "# TYPE cs_gateway_kv_requests_total counter\n")
	fmt.Fprintf(w, "cs_gateway_kv_requests_total %d\n", s.metrics.kvRequests.Load())
	fmt.Fprintf(w, "# HELP cs_gateway_kv_forbidden_total Gateway KV API requests rejected by JWT verification.\n")
	fmt.Fprintf(w, "# TYPE cs_gateway_kv_forbidden_total counter\n")
	fmt.Fprintf(w, "cs_gateway_kv_forbidden_total %d\n", s.metrics.kvForbidden.Load())
	fmt.Fprintf(w, "# HELP cs_gateway_kv_invalid_total Gateway KV API requests rejected as invalid.\n")
	fmt.Fprintf(w, "# TYPE cs_gateway_kv_invalid_total counter\n")
	fmt.Fprintf(w, "cs_gateway_kv_invalid_total %d\n", s.metrics.kvInvalid.Load())
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) kvHTTP(w http.ResponseWriter, r *http.Request) {
	s.metrics.kvRequests.Add(1)
	key := strings.TrimPrefix(r.URL.Path, "/v1/kv/")
	if key == "" || strings.Contains(key, "..") {
		s.metrics.kvInvalid.Add(1)
		http.Error(w, "invalid key", http.StatusBadRequest)
		return
	}
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if _, err := auth.VerifyToken(s.cfg.Secret, token); err != nil {
		s.metrics.kvForbidden.Add(1)
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	switch r.Method {
	case http.MethodGet:
		v, ok := s.kv[key]
		if !ok {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(v)
	case http.MethodPut:
		b, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		s.kv[key] = b
		if err := s.saveKV(); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	case http.MethodDelete:
		delete(s.kv, key)
		if err := s.saveKV(); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) loadKV() error {
	b, err := os.ReadFile(s.cfg.KVPath)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	return json.Unmarshal(b, &s.kv)
}

func (s *Server) saveKV() error {
	if s.cfg.KVPath == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(s.cfg.KVPath), 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(s.kv, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.cfg.KVPath, b, 0o600)
}
