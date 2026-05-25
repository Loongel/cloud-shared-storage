package plugin

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type Config struct {
	SocketPath   string
	DaemonUDS    string
	DockerSocket string
	Scope        string
	Timeout      time.Duration
}

type Server struct {
	cfg      Config
	client   *Client
	docker   *DockerClient
	volumeMu sync.RWMutex
	volumes  map[string]dockerVolumeConfig
}

type Client struct {
	base   string
	socket string
	http   *http.Client
}

type DockerClient struct {
	base   string
	socket string
	http   *http.Client
}

type DockerRequest struct {
	Name   string            `json:"Name"`
	ID     string            `json:"ID,omitempty"`
	Opts   map[string]string `json:"Opts,omitempty"`
	Labels map[string]string `json:"Labels,omitempty"`
}

type DockerVolume struct {
	Name       string            `json:"Name"`
	Mountpoint string            `json:"Mountpoint"`
	CreatedAt  string            `json:"CreatedAt,omitempty"`
	Status     map[string]string `json:"Status,omitempty"`
}

type dockerVolumeConfig struct {
	Labels  map[string]string
	Options map[string]string
}

type dockerResponse struct {
	Err          string         `json:"Err,omitempty"`
	Mountpoint   string         `json:"Mountpoint,omitempty"`
	Volume       *DockerVolume  `json:"Volume,omitempty"`
	Volumes      []DockerVolume `json:"Volumes,omitempty"`
	Implements   []string       `json:"Implements,omitempty"`
	Capabilities map[string]any `json:"Capabilities,omitempty"`
}

type daemonResponse struct {
	Mountpoint string `json:"mountpoint,omitempty"`
	Volume     *struct {
		Name       string `json:"name"`
		Mountpoint string `json:"mountpoint"`
	} `json:"volume,omitempty"`
	Volumes []struct {
		Name       string `json:"name"`
		Mountpoint string `json:"mountpoint"`
	} `json:"volumes,omitempty"`
	Error string `json:"error,omitempty"`
}

func New(cfg Config) *Server {
	if cfg.SocketPath == "" {
		cfg.SocketPath = "/run/docker/plugins/css.sock"
	}
	if cfg.DaemonUDS == "" {
		cfg.DaemonUDS = "/run/cs-storage.sock"
	}
	if cfg.DockerSocket == "" {
		cfg.DockerSocket = "/var/run/docker.sock"
	}
	if cfg.Scope == "" {
		cfg.Scope = "local"
	}
	if cfg.Timeout == 0 {
		cfg.Timeout = 5 * time.Second
	}
	srv := &Server{
		cfg:     cfg,
		client:  NewClient(cfg.DaemonUDS, cfg.Timeout),
		docker:  NewDockerClient(cfg.DockerSocket, cfg.Timeout),
		volumes: map[string]dockerVolumeConfig{},
	}
	return srv
}

func NewClient(socket string, timeout time.Duration) *Client {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", socket)
		},
	}
	return &Client{
		base:   "http://unix",
		socket: socket,
		http:   &http.Client{Transport: transport, Timeout: timeout},
	}
}

func NewDockerClient(socket string, timeout time.Duration) *DockerClient {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", socket)
		},
	}
	return &DockerClient{
		base:   "http://docker",
		socket: socket,
		http:   &http.Client{Transport: transport, Timeout: timeout},
	}
}

func (s *Server) ListenAndServe() error {
	if err := os.MkdirAll(filepath.Dir(s.cfg.SocketPath), 0o755); err != nil {
		return err
	}
	_ = os.Remove(s.cfg.SocketPath)
	ln, err := net.Listen("unix", s.cfg.SocketPath)
	if err != nil {
		return err
	}
	if err := os.Chmod(s.cfg.SocketPath, 0o660); err != nil {
		return err
	}
	log.Printf("cs-storage docker plugin listening on unix://%s", s.cfg.SocketPath)
	return http.Serve(ln, s.routes())
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/Plugin.Activate", s.activate)
	mux.HandleFunc("/VolumeDriver.Capabilities", s.capabilities)
	mux.HandleFunc("/VolumeDriver.Create", s.create)
	mux.HandleFunc("/VolumeDriver.Remove", s.remove)
	mux.HandleFunc("/VolumeDriver.Mount", s.mount)
	mux.HandleFunc("/VolumeDriver.Unmount", s.unmount)
	mux.HandleFunc("/VolumeDriver.Path", s.path)
	mux.HandleFunc("/VolumeDriver.Get", s.get)
	mux.HandleFunc("/VolumeDriver.List", s.list)
	return mux
}

func (s *Server) activate(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, dockerResponse{Implements: []string{"VolumeDriver"}})
}

func (s *Server) capabilities(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, dockerResponse{Capabilities: map[string]any{"Scope": s.cfg.Scope}})
}

func (s *Server) create(w http.ResponseWriter, r *http.Request) {
	var req DockerRequest
	if !decode(w, r, &req) {
		return
	}
	resp, err := s.client.Call(r.Context(), "/v1/create", map[string]any{"name": req.Name, "opts": req.Opts, "labels": req.Labels})
	if err == nil && resp.Error == "" && req.Name != "" {
		s.volumeMu.Lock()
		s.volumes[req.Name] = dockerVolumeConfig{Labels: cloneStringMap(req.Labels), Options: cloneStringMap(req.Opts)}
		s.volumeMu.Unlock()
	}
	writeDocker(w, resp, err)
}

func (s *Server) remove(w http.ResponseWriter, r *http.Request) {
	s.simpleVolumeCall(w, r, "/v1/remove", true)
}

func (s *Server) mount(w http.ResponseWriter, r *http.Request) {
	s.simpleVolumeCall(w, r, "/v1/mount", true)
}

func (s *Server) unmount(w http.ResponseWriter, r *http.Request) {
	s.simpleVolumeCall(w, r, "/v1/unmount", true)
}

func (s *Server) path(w http.ResponseWriter, r *http.Request) {
	s.simpleVolumeCall(w, r, "/v1/path", true)
}

func (s *Server) get(w http.ResponseWriter, r *http.Request) {
	var req DockerRequest
	if !decode(w, r, &req) {
		return
	}
	opts, labels := s.configForRequest(r.Context(), req.Name, req.Opts, req.Labels)
	resp, err := s.client.Call(r.Context(), "/v1/get", map[string]any{"name": req.Name, "opts": opts, "labels": labels})
	if err != nil || resp.Error != "" {
		writeDocker(w, resp, err)
		return
	}
	out := dockerResponse{}
	if resp.Volume != nil {
		out.Volume = &DockerVolume{Name: resp.Volume.Name, Mountpoint: resp.Volume.Mountpoint}
	}
	writeJSON(w, out)
}

func (s *Server) list(w http.ResponseWriter, r *http.Request) {
	resp, err := s.client.Call(r.Context(), "/v1/list", map[string]any{})
	if err != nil || resp.Error != "" {
		writeDocker(w, resp, err)
		return
	}
	out := dockerResponse{Volumes: make([]DockerVolume, 0, len(resp.Volumes))}
	for _, v := range resp.Volumes {
		out.Volumes = append(out.Volumes, DockerVolume{Name: v.Name, Mountpoint: v.Mountpoint})
	}
	writeJSON(w, out)
}

func (s *Server) simpleVolumeCall(w http.ResponseWriter, r *http.Request, endpoint string, includeLabels bool) {
	var req DockerRequest
	if !decode(w, r, &req) {
		return
	}
	opts := cloneStringMap(req.Opts)
	var labels map[string]string
	if includeLabels {
		opts, labels = s.configForRequest(r.Context(), req.Name, req.Opts, req.Labels)
	}
	resp, err := s.client.Call(r.Context(), endpoint, map[string]any{"name": req.Name, "id": req.ID, "opts": opts, "labels": labels})
	writeDocker(w, resp, err)
}

func (s *Server) configForRequest(ctx context.Context, name string, explicitOpts map[string]string, explicitLabels map[string]string) (map[string]string, map[string]string) {
	opts := cloneStringMap(explicitOpts)
	labels := cloneStringMap(explicitLabels)
	if name == "" {
		return opts, labels
	}
	if len(opts) > 0 && len(labels) > 0 {
		return opts, labels
	}
	_ = ctx
	s.volumeMu.RLock()
	cached := s.volumes[name]
	s.volumeMu.RUnlock()
	if len(opts) == 0 {
		opts = cloneStringMap(cached.Options)
	}
	if len(labels) == 0 {
		labels = cloneStringMap(cached.Labels)
	}
	return opts, labels
}

func (s *Server) watchDockerVolumes() {
	s.refreshDockerVolumes()
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for range ticker.C {
		s.refreshDockerVolumes()
	}
}

func (s *Server) refreshDockerVolumes() {
	ctx, cancel := context.WithTimeout(context.Background(), s.cfg.Timeout)
	defer cancel()
	volumes, err := s.docker.ListVolumeConfig(ctx)
	if err != nil {
		return
	}
	s.volumeMu.Lock()
	s.volumes = volumes
	s.volumeMu.Unlock()
}

func (c *DockerClient) ListVolumeConfig(ctx context.Context) (map[string]dockerVolumeConfig, error) {
	if c.socket == "" {
		return nil, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+"/volumes", nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("docker unavailable on %s: %w", c.socket, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("docker volume list returned %s", resp.Status)
	}
	var out struct {
		Volumes []struct {
			Name    string            `json:"Name"`
			Labels  map[string]string `json:"Labels"`
			Options map[string]string `json:"Options"`
		} `json:"Volumes"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, err
	}
	volumes := make(map[string]dockerVolumeConfig, len(out.Volumes))
	for _, v := range out.Volumes {
		volumes[v.Name] = dockerVolumeConfig{Labels: cloneStringMap(v.Labels), Options: cloneStringMap(v.Options)}
	}
	return volumes, nil
}

func (c *DockerClient) VolumeConfig(ctx context.Context, name string) (dockerVolumeConfig, error) {
	if c.socket == "" {
		return dockerVolumeConfig{}, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+"/volumes/"+url.PathEscape(name), nil)
	if err != nil {
		return dockerVolumeConfig{}, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return dockerVolumeConfig{}, fmt.Errorf("docker unavailable on %s: %w", c.socket, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return dockerVolumeConfig{}, nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return dockerVolumeConfig{}, fmt.Errorf("docker volume inspect returned %s", resp.Status)
	}
	var out struct {
		Labels  map[string]string `json:"Labels"`
		Options map[string]string `json:"Options"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return dockerVolumeConfig{}, err
	}
	return dockerVolumeConfig{Labels: cloneStringMap(out.Labels), Options: cloneStringMap(out.Options)}, nil
}

func (c *Client) Call(ctx context.Context, endpoint string, payload any) (daemonResponse, error) {
	var out daemonResponse
	b, err := json.Marshal(payload)
	if err != nil {
		return out, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.base+endpoint, bytes.NewReader(b))
	if err != nil {
		return out, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return out, fmt.Errorf("daemon unavailable on %s: %w", c.socket, err)
	}
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return out, err
	}
	return out, nil
}

func writeDocker(w http.ResponseWriter, resp daemonResponse, err error) {
	if err != nil {
		writeJSON(w, dockerResponse{Err: err.Error()})
		return
	}
	if resp.Error != "" {
		writeJSON(w, dockerResponse{Err: resp.Error})
		return
	}
	writeJSON(w, dockerResponse{Mountpoint: resp.Mountpoint})
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	if r.Method != http.MethodPost {
		writeJSON(w, dockerResponse{Err: "method not allowed"})
		return false
	}
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		writeJSON(w, dockerResponse{Err: "invalid json: " + err.Error()})
		return false
	}
	return true
}

func cloneStringMap(in map[string]string) map[string]string {
	if len(in) == 0 {
		return nil
	}
	out := make(map[string]string, len(in))
	for k, v := range in {
		out[k] = v
	}
	return out
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
