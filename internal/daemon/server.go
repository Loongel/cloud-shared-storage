package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"cs-storage/internal/volume"
)

type Config struct {
	ServerURL             string
	NodeID                string
	NodeSecret            string
	RcloneEndpoint        string
	RcloneBinary          string
	RcloneVFSCacheMode    string
	RcloneVFSWriteBack    string
	RcloneVFSCacheMaxSize string
	RcloneExtraArgs       string
	RcloneSyncInterval    time.Duration
	RcloneSyncSource      string
	RcloneSyncTarget      string
	GocryptfsBinary       string
	GocryptfsPassword     string
	GocryptfsExtraArgs    string
	GlusterBinary         string
	GlusterRemote         string
	GlusterExtraArgs      string
	LiteFSBinary          string
	LiteFSConfig          string
	LiteFSHTTPAddr        string
	LiteFSLeaseType       string
	LiteFSAdvertiseURL    string
	LiteFSConsulURL       string
	LiteFSConsulKey       string
	LiteFSConsulTTL       string
	LiteFSConsulLockDelay string
	LiteFSHostname        string
	LiteFSPromote         bool
	LiteFSConsulToken     string
	LiteFSCandidate       bool
	KopiaBinary           string
	KopiaRepository       string
	KopiaConfigPath       string
	KopiaPassword         string
	KopiaExtraArgs        string
	KopiaPolicyArgs       string
	KopiaSnapshotInterval time.Duration
	RouterBinary          string
	RouterExtraArgs       string
	SocketPath            string
	RootDir               string
	StatePath             string
	AuditLogPath          string
	RcloneRCAddr          string
	RcloneRCUser          string
	RcloneRCPassword      string
	EnableChattr          bool
	RecoverMounts         bool
	ManagedVolumes        string
	ManagedEnsureInterval time.Duration
}

type Server struct {
	cfg    Config
	store  *volume.Store
	procs  *ProcessManager
	syncs  *PeriodicSyncManager
	rootMu sync.Mutex
}

type CreateRequest struct {
	Name   string            `json:"name"`
	Opts   map[string]string `json:"opts"`
	Labels map[string]string `json:"labels,omitempty"`
}

type VolumeRequest struct {
	Name   string            `json:"name"`
	ID     string            `json:"id,omitempty"`
	Opts   map[string]string `json:"opts,omitempty"`
	Labels map[string]string `json:"labels,omitempty"`
}

type VolumeResponse struct {
	Mountpoint string            `json:"mountpoint,omitempty"`
	Volume     *volume.Metadata  `json:"volume,omitempty"`
	Volumes    []volume.Metadata `json:"volumes,omitempty"`
	Plan       *Pipeline         `json:"plan,omitempty"`
	Error      string            `json:"error,omitempty"`
}

func New(cfg Config) (*Server, error) {
	if cfg.SocketPath == "" {
		cfg.SocketPath = "/run/cs-storage.sock"
	}
	if cfg.RootDir == "" {
		cfg.RootDir = "/mnt/cs_storage/vols"
	}
	if cfg.StatePath == "" {
		cfg.StatePath = filepath.Join(cfg.RootDir, ".state", "volumes.json")
	}
	if cfg.AuditLogPath == "" {
		cfg.AuditLogPath = filepath.Join(filepath.Dir(cfg.StatePath), "audit.jsonl")
	}
	store, err := volume.NewStore(cfg.StatePath)
	if err != nil {
		return nil, err
	}
	return &Server{
		cfg:   cfg,
		store: store,
		procs: NewProcessManager(),
		syncs: NewPeriodicSyncManager(),
	}, nil
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
	s.recoverState()
	if err := s.setRootImmutable(true); err != nil {
		return err
	}
	if s.cfg.ManagedVolumes != "" {
		s.startManagedVolumes()
	}
	log.Printf("cs-storage daemon listening on unix://%s", s.cfg.SocketPath)
	return http.Serve(ln, s.routes())
}

func (s *Server) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/readyz", s.readyz)
	mux.HandleFunc("/metrics", s.metricsHTTP)
	mux.HandleFunc("/v1/create", s.create)
	mux.HandleFunc("/v1/remove", s.remove)
	mux.HandleFunc("/v1/mount", s.mount)
	mux.HandleFunc("/v1/unmount", s.unmount)
	mux.HandleFunc("/v1/path", s.path)
	mux.HandleFunc("/v1/get", s.get)
	mux.HandleFunc("/v1/list", s.list)
	mux.HandleFunc("/v1/plan", s.plan)
	return mux
}

func (s *Server) readyz(w http.ResponseWriter, r *http.Request) {
	unhealthy := s.procs.UnhealthyCount()
	if unhealthy > 0 {
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintf(w, "unhealthy managed processes: %d\n", unhealthy)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) metricsHTTP(w http.ResponseWriter, r *http.Request) {
	volumes := s.store.List()
	mountedVolumes := 0
	mountRefs := 0
	for _, v := range volumes {
		if len(v.MountIDs) > 0 {
			mountedVolumes++
			mountRefs += len(v.MountIDs)
		}
	}
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "# HELP cs_daemon_volumes_total Configured cs-storage volumes.\n")
	fmt.Fprintf(w, "# TYPE cs_daemon_volumes_total gauge\n")
	fmt.Fprintf(w, "cs_daemon_volumes_total %d\n", len(volumes))
	fmt.Fprintf(w, "# HELP cs_daemon_mounted_volumes_total Volumes with at least one active Docker mount reference.\n")
	fmt.Fprintf(w, "# TYPE cs_daemon_mounted_volumes_total gauge\n")
	fmt.Fprintf(w, "cs_daemon_mounted_volumes_total %d\n", mountedVolumes)
	fmt.Fprintf(w, "# HELP cs_daemon_mount_refs_total Active Docker mount references tracked by the daemon.\n")
	fmt.Fprintf(w, "# TYPE cs_daemon_mount_refs_total gauge\n")
	fmt.Fprintf(w, "cs_daemon_mount_refs_total %d\n", mountRefs)
	processStats := s.procs.Stats()
	fmt.Fprintf(w, "# HELP cs_daemon_managed_processes_total Child storage processes currently tracked by the daemon.\n")
	fmt.Fprintf(w, "# TYPE cs_daemon_managed_processes_total gauge\n")
	fmt.Fprintf(w, "cs_daemon_managed_processes_total %d\n", s.procs.Count())
	fmt.Fprintf(w, "# HELP cs_daemon_desired_processes_total Child storage processes the daemon intends to keep running.\n")
	fmt.Fprintf(w, "# TYPE cs_daemon_desired_processes_total gauge\n")
	fmt.Fprintf(w, "cs_daemon_desired_processes_total %d\n", s.procs.DesiredCount())
	fmt.Fprintf(w, "# HELP cs_daemon_unhealthy_processes_total Desired child storage processes that are not currently running.\n")
	fmt.Fprintf(w, "# TYPE cs_daemon_unhealthy_processes_total gauge\n")
	fmt.Fprintf(w, "cs_daemon_unhealthy_processes_total %d\n", s.procs.UnhealthyCount())
	fmt.Fprintf(w, "# HELP cs_daemon_process_starts_total Child storage process starts observed by the daemon.\n")
	fmt.Fprintf(w, "# TYPE cs_daemon_process_starts_total counter\n")
	fmt.Fprintf(w, "cs_daemon_process_starts_total %d\n", processStats.Starts)
	fmt.Fprintf(w, "# HELP cs_daemon_process_exits_total Child storage process exits observed by the daemon.\n")
	fmt.Fprintf(w, "# TYPE cs_daemon_process_exits_total counter\n")
	fmt.Fprintf(w, "cs_daemon_process_exits_total %d\n", processStats.Exits)
	fmt.Fprintf(w, "# HELP cs_daemon_process_restart_attempts_total Child storage process restart attempts.\n")
	fmt.Fprintf(w, "# TYPE cs_daemon_process_restart_attempts_total counter\n")
	fmt.Fprintf(w, "cs_daemon_process_restart_attempts_total %d\n", processStats.RestartAttempts)
	fmt.Fprintf(w, "# HELP cs_daemon_process_restart_successes_total Child storage process restart attempts that started a replacement process.\n")
	fmt.Fprintf(w, "# TYPE cs_daemon_process_restart_successes_total counter\n")
	fmt.Fprintf(w, "cs_daemon_process_restart_successes_total %d\n", processStats.RestartSuccesses)
	fmt.Fprintf(w, "# HELP cs_daemon_process_restart_failures_total Child storage process restart attempts that failed to start.\n")
	fmt.Fprintf(w, "# TYPE cs_daemon_process_restart_failures_total counter\n")
	fmt.Fprintf(w, "cs_daemon_process_restart_failures_total %d\n", processStats.RestartFailures)
	fmt.Fprintf(w, "# HELP cs_daemon_shared_multi_volumes_total Configured shared multi-write volumes.\n")
	fmt.Fprintf(w, "# TYPE cs_daemon_shared_multi_volumes_total gauge\n")
	fmt.Fprintf(w, "cs_daemon_shared_multi_volumes_total %d\n", 0)
	fmt.Fprintf(w, "# HELP cs_daemon_backup_enabled_volumes_total Volumes configured with cs.backup=true.\n")
	fmt.Fprintf(w, "# TYPE cs_daemon_backup_enabled_volumes_total gauge\n")
	fmt.Fprintf(w, "cs_daemon_backup_enabled_volumes_total %d\n", 0)
}

func (s *Server) create(w http.ResponseWriter, r *http.Request) {
	var req CreateRequest
	if !decode(w, r, &req) {
		return
	}
	if req.Name == "" {
		s.auditError("create", req.Name, "", "missing volume name")
		writeError(w, "missing volume name")
		return
	}
	opts, err := volume.ParseDriverOptions(req.Opts, req.Labels)
	if err != nil {
		s.auditError("create", req.Name, "", err.Error())
		writeError(w, err.Error())
		return
	}
	layout := s.layout(req.Name)
	mountpoint := layout.Mountpoint
	err = s.withRootMutable(func() error {
		if opts.Flush {
			if existing, ok := s.store.Get(req.Name); ok {
				if err := s.stopVolumeProcesses(existing); err != nil {
					return err
				}
			}
			for _, path := range []string{layout.Mountpoint, layout.Remote, layout.Cipher, layout.Gluster, layout.LiteFSMount} {
				if err := unmountPath(path); err != nil {
					return err
				}
			}
			if err := os.RemoveAll(s.volumeRoot(req.Name)); err != nil {
				return err
			}
		}
		for _, dir := range []string{layout.Mountpoint, layout.Remote, layout.Cipher, layout.Cache, layout.Logs, layout.Config, layout.LiteFSData, layout.LiteFSMount, layout.Gluster, layout.LocalDisk} {
			if err := os.MkdirAll(dir, 0o700); err != nil {
				return err
			}
		}
		storedOpts := opts
		storedOpts.Flush = false
		m := volume.Metadata{Name: req.Name, Mountpoint: mountpoint, Options: storedOpts}
		if existing, ok := s.store.Get(req.Name); ok {
			m.MountIDs = existing.MountIDs
		}
		return s.store.Upsert(m)
	})
	if err != nil {
		s.auditError("create", req.Name, "", err.Error())
		writeError(w, err.Error())
		return
	}
	runtimeMeta := volume.Metadata{Name: req.Name, Mountpoint: mountpoint, Options: opts}
	if opts.Flush {
		if err := s.resetRealtimeRemote(r.Context(), runtimeMeta); err != nil {
			s.auditError("create", req.Name, "", err.Error())
			writeError(w, err.Error())
			return
		}
	}
	if err := s.ensurePeriodicBackup(r.Context(), runtimeMeta); err != nil {
		s.auditError("create", req.Name, "", err.Error())
		writeError(w, err.Error())
		return
	}
	s.auditSuccess("create", runtimeMeta, "")
	writeJSON(w, VolumeResponse{Mountpoint: mountpoint})
}

func (s *Server) remove(w http.ResponseWriter, r *http.Request) {
	var req VolumeRequest
	if !decode(w, r, &req) {
		return
	}
	meta, ok := s.store.Get(req.Name)
	if !ok {
		s.audit("remove", nil, req.Name, "", "ok", "volume already absent")
		writeJSON(w, VolumeResponse{})
		return
	}
	runtimeMeta, opts, err := s.requestMetadata(meta, req.Opts, req.Labels)
	if err != nil {
		s.auditError("remove", req.Name, req.ID, err.Error())
		writeError(w, err.Error())
		return
	}
	if meta.MountIDs[daemonManagedMountID] && !opts.Flush {
		s.audit("remove", &runtimeMeta, req.Name, req.ID, "ok", "managed volume retained")
		writeJSON(w, VolumeResponse{})
		return
	}
	if err := s.stopVolumeProcesses(runtimeMeta); err != nil {
		s.auditError("remove", req.Name, req.ID, err.Error())
		writeError(w, err.Error())
		return
	}
	if err := s.withRootMutable(func() error {
		if opts.Flush {
			if err := os.RemoveAll(s.volumeRoot(req.Name)); err != nil {
				return err
			}
		}
		return s.store.Delete(req.Name)
	}); err != nil {
		s.auditError("remove", req.Name, req.ID, err.Error())
		writeError(w, err.Error())
		return
	}
	s.auditSuccess("remove", runtimeMeta, req.ID)
	writeJSON(w, VolumeResponse{})
}

func (s *Server) mount(w http.ResponseWriter, r *http.Request) {
	var req VolumeRequest
	if !decode(w, r, &req) {
		return
	}
	meta, ok := s.store.Get(req.Name)
	if !ok {
		s.auditError("mount", req.Name, req.ID, "volume not found")
		writeError(w, "volume not found")
		return
	}
	runtimeMeta, _, err := s.requestMetadata(meta, req.Opts, req.Labels)
	if err != nil {
		s.auditError("mount", req.Name, req.ID, err.Error())
		writeError(w, err.Error())
		return
	}
	s.rootMu.Lock()
	defer s.rootMu.Unlock()
	layout := s.layout(req.Name)
	for _, dir := range layoutDirsFor(runtimeMeta, layout) {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			s.auditError("mount", req.Name, req.ID, err.Error())
			writeError(w, err.Error())
			return
		}
	}
	if err := s.ensureRealtimeRclone(r.Context(), runtimeMeta); err != nil {
		s.auditError("mount", req.Name, req.ID, err.Error())
		writeError(w, err.Error())
		return
	}
	if err := s.ensureMountReady(req.Name, runtimeMeta); err != nil {
		s.auditError("mount", req.Name, req.ID, err.Error())
		writeError(w, err.Error())
		return
	}
	if err := s.forgetRcloneVFS(r.Context(), runtimeMeta); err != nil {
		s.auditError("mount", req.Name, req.ID, err.Error())
		writeError(w, err.Error())
		return
	}
	addMountRef(&meta, req.ID)
	if err := s.store.Upsert(meta); err != nil {
		s.auditError("mount", req.Name, req.ID, err.Error())
		writeError(w, err.Error())
		return
	}
	if err := s.ensurePeriodicBackup(r.Context(), runtimeMeta); err != nil {
		s.auditError("mount", req.Name, req.ID, err.Error())
		writeError(w, err.Error())
		return
	}
	s.auditSuccess("mount", runtimeMeta, req.ID)
	writeJSON(w, VolumeResponse{Mountpoint: runtimeMeta.Mountpoint})
}

func (s *Server) unmount(w http.ResponseWriter, r *http.Request) {
	var req VolumeRequest
	if !decode(w, r, &req) {
		return
	}
	meta, ok := s.store.Get(req.Name)
	if !ok {
		s.auditError("unmount", req.Name, req.ID, "volume not found")
		writeError(w, "volume not found")
		return
	}
	runtimeMeta, _, err := s.requestMetadata(meta, req.Opts, req.Labels)
	if err != nil {
		s.auditError("unmount", req.Name, req.ID, err.Error())
		writeError(w, err.Error())
		return
	}
	removeMountRef(&meta, req.ID)
	if !hasMountRefs(meta) {
		if err := s.stopVolumeProcesses(runtimeMeta); err != nil {
			s.auditError("unmount", req.Name, req.ID, err.Error())
			writeError(w, err.Error())
			return
		}
	}
	if err := s.store.Upsert(meta); err != nil {
		s.auditError("unmount", req.Name, req.ID, err.Error())
		writeError(w, err.Error())
		return
	}
	runtimeMeta.MountIDs = meta.MountIDs
	s.auditSuccess("unmount", runtimeMeta, req.ID)
	writeJSON(w, VolumeResponse{})
}

func (s *Server) path(w http.ResponseWriter, r *http.Request) {
	var req VolumeRequest
	if !decode(w, r, &req) {
		return
	}
	meta, ok := s.store.Get(req.Name)
	if !ok {
		writeError(w, "volume not found")
		return
	}
	runtimeMeta, _, err := s.requestMetadata(meta, req.Opts, req.Labels)
	if err != nil {
		writeError(w, err.Error())
		return
	}
	writeJSON(w, VolumeResponse{Mountpoint: runtimeMeta.Mountpoint})
}

func (s *Server) get(w http.ResponseWriter, r *http.Request) {
	var req VolumeRequest
	if !decode(w, r, &req) {
		return
	}
	meta, ok := s.store.Get(req.Name)
	if !ok {
		writeError(w, "volume not found")
		return
	}
	runtimeMeta, _, err := s.requestMetadata(meta, req.Opts, req.Labels)
	if err != nil {
		writeError(w, err.Error())
		return
	}
	writeJSON(w, VolumeResponse{Volume: &runtimeMeta})
}

func (s *Server) list(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, VolumeResponse{Volumes: s.store.List()})
}

func (s *Server) plan(w http.ResponseWriter, r *http.Request) {
	var req VolumeRequest
	if !decode(w, r, &req) {
		return
	}
	meta, ok := s.store.Get(req.Name)
	if !ok {
		writeError(w, "volume not found")
		return
	}
	runtimeMeta, _, err := s.requestMetadata(meta, req.Opts, req.Labels)
	if err != nil {
		writeError(w, err.Error())
		return
	}
	plan := PlanPipeline(runtimeMeta.Options)
	writeJSON(w, VolumeResponse{Plan: &plan})
}

func (s *Server) requestMetadata(meta volume.Metadata, optsRaw, labelsRaw map[string]string) (volume.Metadata, volume.Options, error) {
	if len(optsRaw) == 0 && len(labelsRaw) == 0 && meta.MountIDs[daemonManagedMountID] {
		if managed, ok := s.managedOptionsFor(meta.Name); ok {
			optsRaw = managed
		}
	}
	if len(optsRaw) == 0 && len(labelsRaw) == 0 && metadataOptionsSet(meta.Options) {
		meta.Options.Flush = false
		return meta, meta.Options, nil
	}
	opts, err := volume.ParseDriverOptions(optsRaw, labelsRaw)
	if err != nil {
		return meta, opts, err
	}
	meta.Options = opts
	return meta, opts, nil
}

func metadataOptionsSet(opts volume.Options) bool {
	return opts.Mode != "" || opts.Write != "" || opts.Engine != "" || opts.Backup
}

func (s *Server) managedOptionsFor(name string) (map[string]string, bool) {
	specs, err := parseManagedVolumes(s.cfg.ManagedVolumes)
	if err != nil {
		return nil, false
	}
	for _, spec := range specs {
		if spec.Name == name {
			return managedVolumeOptions(spec.Opts), true
		}
	}
	return nil, false
}

func (s *Server) withRootMutable(fn func() error) error {
	s.rootMu.Lock()
	defer s.rootMu.Unlock()
	if err := s.setRootImmutable(false); err != nil {
		return err
	}
	err := fn()
	if guardErr := s.setRootImmutable(true); guardErr != nil {
		return errors.Join(err, guardErr)
	}
	return err
}

func (s *Server) setRootImmutable(enabled bool) error {
	if !s.cfg.EnableChattr {
		return nil
	}
	if err := os.MkdirAll(s.cfg.RootDir, 0o700); err != nil {
		return err
	}
	return setImmutable(s.cfg.RootDir, enabled)
}

func (s *Server) volumeRoot(name string) string {
	return filepath.Join(s.cfg.RootDir, filepath.Clean("/"+name))
}

func (s *Server) mountpoint(name string) string {
	return s.layout(name).Mountpoint
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	if r.Method != http.MethodPost {
		writeError(w, "method not allowed")
		return false
	}
	if err := json.NewDecoder(r.Body).Decode(v); err != nil {
		writeError(w, "invalid json: "+err.Error())
		return false
	}
	return true
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, msg string) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(VolumeResponse{Error: msg})
}

func setImmutable(path string, enabled bool) error {
	if _, err := exec.LookPath("chattr"); err != nil {
		if errors.Is(err, exec.ErrNotFound) {
			return nil
		}
		return err
	}
	flag := "-i"
	if enabled {
		flag = "+i"
	}
	out, err := exec.Command("chattr", flag, path).CombinedOutput()
	if err != nil {
		if isChattrUnsupported(string(out)) {
			log.Printf("chattr %s unsupported for %s; continuing without immutable root guard: %s", flag, path, strings.TrimSpace(string(out)))
			return nil
		}
		return fmt.Errorf("chattr %s %s failed: %w: %s", flag, path, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func isChattrUnsupported(output string) bool {
	msg := strings.ToLower(output)
	return strings.Contains(msg, "operation not permitted") ||
		strings.Contains(msg, "inappropriate ioctl") ||
		strings.Contains(msg, "not supported") ||
		strings.Contains(msg, "operation not supported")
}
