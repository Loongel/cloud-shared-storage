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

func TestRouterDoesNotPinVolumeRoot(t *testing.T) {
	r := New()
	if got := r.Route("/main.db"); got != EngineLiteFS {
		t.Fatalf("expected root db to use litefs, got %s", got)
	}
	if got := r.Route("/css-scenario-test/writers/node.txt"); got != EngineGluster {
		t.Fatalf("expected non-sqlite root child to remain on gluster, got %s", got)
	}
	if got := r.Route("/main.db-wal"); got != EngineLiteFS {
		t.Fatalf("expected root db wal to use litefs, got %s", got)
	}
}
