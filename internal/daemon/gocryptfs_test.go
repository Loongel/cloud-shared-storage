package daemon

import (
	"strings"
	"testing"
)

func TestGocryptfsMountArgsRunInForeground(t *testing.T) {
	args := gocryptfsMountArgs("/pass", "/cipher", "/cache", []string{"-sharedstorage"})
	joined := strings.Join(args, "\x00")
	if !strings.Contains(joined, "-fg") {
		t.Fatalf("gocryptfs must run in foreground for process supervision: %#v", args)
	}
	for _, want := range []string{"-sharedstorage", "-passfile\x00/pass", "/cipher", "/cache"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing %q in args %#v", want, args)
		}
	}
}
