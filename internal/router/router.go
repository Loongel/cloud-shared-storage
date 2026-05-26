package router

import (
	"path/filepath"
	"strings"
	"sync"
)

type Engine string

const (
	EngineGluster Engine = "gluster"
	EngineLiteFS  Engine = "litefs"
)

type Router struct {
	mu         sync.Mutex
	sqliteDirs map[string]bool
}

func New() *Router {
	return &Router{sqliteDirs: map[string]bool{}}
}

func (r *Router) Route(path string) Engine {
	clean := filepath.Clean("/" + path)
	dir := filepath.Dir(clean)
	base := strings.ToLower(filepath.Base(clean))
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.sqliteDirs[dir] || isSQLiteFile(base) || isSQLiteCompanion(base) {
		if dir != "/" && (isSQLiteFile(base) || isSQLiteCompanion(base)) {
			r.sqliteDirs[dir] = true
		}
		return EngineLiteFS
	}
	return EngineGluster
}

func (r *Router) SQLiteDirs() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, 0, len(r.sqliteDirs))
	for dir := range r.sqliteDirs {
		out = append(out, dir)
	}
	return out
}

func isSQLiteFile(base string) bool {
	return strings.HasSuffix(base, ".db") || strings.HasSuffix(base, ".sqlite") || strings.HasSuffix(base, ".sqlite3")
}

func isSQLiteCompanion(base string) bool {
	return strings.HasSuffix(base, "-wal") || strings.HasSuffix(base, "-shm") || strings.HasSuffix(base, "-journal")
}
