package router

import "testing"

func TestRouterPinsSQLiteDirectory(t *testing.T) {
	r := New()
	if got := r.Route("/app/config.yml"); got != EngineGluster {
		t.Fatalf("expected config to use gluster, got %s", got)
	}
	if got := r.Route("/app/data/main.db"); got != EngineLiteFS {
		t.Fatalf("expected db to use litefs, got %s", got)
	}
	if got := r.Route("/app/data/other.txt"); got != EngineLiteFS {
		t.Fatalf("expected pinned sqlite directory to use litefs, got %s", got)
	}
}

func TestRouterSQLiteCompanion(t *testing.T) {
	r := New()
	if got := r.Route("/app/main.db-wal"); got != EngineLiteFS {
		t.Fatalf("expected sqlite wal to use litefs, got %s", got)
	}
}
