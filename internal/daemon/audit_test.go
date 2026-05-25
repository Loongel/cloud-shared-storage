package daemon

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
)

func TestAuditLogRecordsCreateAndError(t *testing.T) {
	root := t.TempDir()
	auditPath := filepath.Join(root, "audit.jsonl")
	s, err := New(Config{RootDir: root, StatePath: filepath.Join(root, ".state", "volumes.json"), AuditLogPath: auditPath})
	if err != nil {
		t.Fatal(err)
	}

	w := httptest.NewRecorder()
	s.create(w, httptest.NewRequest(http.MethodPost, "/v1/create", bytes.NewBufferString(`{"name":"vol","opts":{"cs.crypt":"false"}}`)))
	assertNoDaemonError(t, w.Body.Bytes())

	w = httptest.NewRecorder()
	s.mount(w, httptest.NewRequest(http.MethodPost, "/v1/mount", bytes.NewBufferString(`{"name":"missing","id":"m1"}`)))
	if !strings.Contains(w.Body.String(), "volume not found") {
		t.Fatalf("expected mount error, got %s", w.Body.String())
	}

	records := readAuditRecords(t, auditPath)
	if len(records) != 2 {
		t.Fatalf("expected 2 audit records, got %d: %#v", len(records), records)
	}
	if records[0].Event != "create" || records[0].Volume != "vol" || records[0].Status != "ok" || records[0].Options == nil || records[0].Options.Crypt {
		t.Fatalf("unexpected create audit record: %#v", records[0])
	}
	if records[1].Event != "mount" || records[1].Volume != "missing" || records[1].MountID != "m1" || records[1].Status != "error" || !strings.Contains(records[1].Error, "volume not found") {
		t.Fatalf("unexpected mount audit record: %#v", records[1])
	}
}

func TestDefaultAuditLogPathFollowsStatePath(t *testing.T) {
	root := t.TempDir()
	s, err := New(Config{RootDir: root, StatePath: filepath.Join(root, "state", "volumes.json")})
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(root, "state", "audit.jsonl")
	if s.cfg.AuditLogPath != want {
		t.Fatalf("audit path mismatch: got %q want %q", s.cfg.AuditLogPath, want)
	}
}

func readAuditRecords(t *testing.T, path string) []auditRecord {
	t.Helper()
	b := readFile(t, path)
	lines := strings.Split(strings.TrimSpace(b), "\n")
	records := make([]auditRecord, 0, len(lines))
	for _, line := range lines {
		var rec auditRecord
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("invalid audit json %q: %v", line, err)
		}
		records = append(records, rec)
	}
	return records
}
