package gateway

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"cs-storage/internal/auth"
)

type consulSession struct {
	ID        string        `json:"ID"`
	Name      string        `json:"Name,omitempty"`
	Node      string        `json:"Node,omitempty"`
	Behavior  string        `json:"Behavior,omitempty"`
	TTL       string        `json:"TTL,omitempty"`
	LockDelay time.Duration `json:"LockDelay,omitempty"`
	Created   time.Time     `json:"Created"`
}

type consulKVEntry struct {
	LockIndex   uint64 `json:"LockIndex"`
	Key         string `json:"Key"`
	Flags       uint64 `json:"Flags"`
	Value       string `json:"Value"`
	CreateIndex uint64 `json:"CreateIndex"`
	ModifyIndex uint64 `json:"ModifyIndex"`
	Session     string `json:"Session,omitempty"`
}

func (s *Server) consulKVHTTP(w http.ResponseWriter, r *http.Request) {
	s.metrics.kvRequests.Add(1)
	key := strings.TrimPrefix(r.URL.Path, "/v1/kv/")
	if key == "" || strings.Contains(key, "..") {
		s.metrics.kvInvalid.Add(1)
		http.Error(w, "invalid key", http.StatusBadRequest)
		return
	}
	if !s.verifyCoordinator(w, r) {
		s.metrics.kvForbidden.Add(1)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.expireSessionsLocked(time.Now())

	s.ensureKVIndexLocked(key)
	switch r.Method {
	case http.MethodGet:
		v, ok := s.kv[key]
		if !ok {
			http.NotFound(w, r)
			return
		}
		entry := s.consulKVEntryLocked(key, v)
		w.Header().Set("X-Consul-Index", fmt.Sprint(entry.ModifyIndex))
		if _, raw := r.URL.Query()["raw"]; raw {
			_, _ = w.Write(v)
			return
		}
		writeJSON(w, []consulKVEntry{entry})
	case http.MethodPut:
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if cas := r.URL.Query().Get("cas"); cas != "" {
			if !s.casKVLocked(key, cas) {
				writeConsulBool(w, false)
				return
			}
		}
		if acquire := r.URL.Query().Get("acquire"); acquire != "" {
			if !s.acquireKVLocked(key, acquire) {
				writeConsulBool(w, false)
				return
			}
		}
		if release := r.URL.Query().Get("release"); release != "" {
			if s.kvLocks[key] != release {
				writeConsulBool(w, false)
				return
			}
			delete(s.kvLocks, key)
		}
		s.kv[key] = body
		s.bumpKVIndexLocked(key)
		if err := s.saveKV(); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeConsulBool(w, true)
	case http.MethodDelete:
		delete(s.kv, key)
		delete(s.kvLocks, key)
		s.bumpKVIndexLocked(key)
		if err := s.saveKV(); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeConsulBool(w, true)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (s *Server) consulSessionHTTP(w http.ResponseWriter, r *http.Request) {
	if !s.verifyCoordinator(w, r) {
		s.metrics.kvForbidden.Add(1)
		return
	}
	trimmed := strings.TrimPrefix(r.URL.Path, "/v1/session/")
	parts := strings.Split(strings.Trim(trimmed, "/"), "/")
	if len(parts) == 0 || parts[0] == "" {
		http.Error(w, "invalid session path", http.StatusBadRequest)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	s.expireSessionsLocked(time.Now())

	switch parts[0] {
	case "create":
		if r.Method != http.MethodPut {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		var req struct {
			Name      string `json:"Name"`
			Node      string `json:"Node"`
			Behavior  string `json:"Behavior"`
			TTL       string `json:"TTL"`
			LockDelay string `json:"LockDelay"`
		}
		_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req)
		id := newSessionID()
		if req.Behavior == "" {
			req.Behavior = "release"
		}
		lockDelay, err := time.ParseDuration(req.LockDelay)
		if req.LockDelay != "" && err != nil {
			http.Error(w, "invalid LockDelay", http.StatusBadRequest)
			return
		}
		s.sessions[id] = consulSession{ID: id, Name: req.Name, Node: req.Node, Behavior: req.Behavior, TTL: req.TTL, LockDelay: lockDelay, Created: time.Now().UTC()}
		writeJSON(w, map[string]string{"ID": id})
	case "destroy":
		if r.Method != http.MethodPut || len(parts) != 2 || parts[1] == "" {
			http.Error(w, "invalid destroy request", http.StatusBadRequest)
			return
		}
		id := parts[1]
		delete(s.sessions, id)
		for key, holder := range s.kvLocks {
			if holder == id {
				delete(s.kvLocks, key)
			}
		}
		writeConsulBool(w, true)
	case "info":
		if r.Method != http.MethodGet || len(parts) != 2 || parts[1] == "" {
			http.Error(w, "invalid info request", http.StatusBadRequest)
			return
		}
		if sess, ok := s.sessions[parts[1]]; ok {
			writeJSON(w, []consulSession{sess})
			return
		}
		writeJSON(w, []consulSession{})
	case "renew":
		if r.Method != http.MethodPut || len(parts) != 2 || parts[1] == "" {
			http.Error(w, "invalid renew request", http.StatusBadRequest)
			return
		}
		if sess, ok := s.sessions[parts[1]]; ok {
			sess.Created = time.Now().UTC()
			s.sessions[parts[1]] = sess
			writeJSON(w, []consulSession{sess})
			return
		}
		writeJSON(w, []consulSession{})
	default:
		http.Error(w, "unsupported session endpoint", http.StatusNotFound)
	}
}

func (s *Server) expireSessionsLocked(now time.Time) {
	for id, sess := range s.sessions {
		if sess.TTL == "" {
			continue
		}
		ttl, err := time.ParseDuration(sess.TTL)
		if err != nil || ttl <= 0 {
			continue
		}
		if now.Sub(sess.Created) <= ttl {
			continue
		}
		delete(s.sessions, id)
		for key, holder := range s.kvLocks {
			if holder == id {
				delete(s.kvLocks, key)
			}
		}
	}
}

func (s *Server) verifyCoordinator(w http.ResponseWriter, r *http.Request) bool {
	if token := s.cfg.CoordinatorToken; token != "" {
		if r.Header.Get("X-Consul-Token") == token || r.URL.Query().Get("token") == token {
			return true
		}
	}
	_, ok := s.verifyBearer(w, r)
	return ok
}

func (s *Server) verifyBearer(w http.ResponseWriter, r *http.Request) (auth.Claims, bool) {
	token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	claims, err := auth.VerifyToken(s.cfg.Secret, token)
	if err != nil {
		http.Error(w, "forbidden", http.StatusForbidden)
		return auth.Claims{}, false
	}
	return claims, true
}

func (s *Server) casKVLocked(key string, cas string) bool {
	var want uint64
	if _, err := fmt.Sscan(cas, &want); err != nil {
		return false
	}
	_, exists := s.kv[key]
	if want == 0 {
		return !exists
	}
	return exists && s.ensureKVIndexLocked(key) == want
}

func (s *Server) acquireKVLocked(key string, session string) bool {
	if _, ok := s.sessions[session]; !ok {
		return false
	}
	if holder := s.kvLocks[key]; holder != "" && holder != session {
		return false
	}
	s.kvLocks[key] = session
	return true
}

func (s *Server) consulKVEntryLocked(key string, value []byte) consulKVEntry {
	idx := s.ensureKVIndexLocked(key)
	entry := consulKVEntry{Key: key, Value: base64.StdEncoding.EncodeToString(value), CreateIndex: idx, ModifyIndex: idx}
	if session := s.kvLocks[key]; session != "" {
		entry.LockIndex = 1
		entry.Session = session
	}
	return entry
}

func (s *Server) ensureKVIndexLocked(key string) uint64 {
	if idx := s.kvIndexes[key]; idx != 0 {
		return idx
	}
	idx := s.nextIndex
	if idx == 0 {
		idx = 1
	}
	s.nextIndex = idx + 1
	s.kvIndexes[key] = idx
	return idx
}

func (s *Server) bumpKVIndexLocked(key string) uint64 {
	idx := s.nextIndex
	if idx == 0 {
		idx = 1
	}
	s.nextIndex = idx + 1
	s.kvIndexes[key] = idx
	return idx
}

func writeConsulBool(w http.ResponseWriter, ok bool) {
	w.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(w, "%t", ok)
}

func newSessionID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(b[:])
}
