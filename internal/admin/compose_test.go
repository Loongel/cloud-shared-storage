package admin

import (
	"strings"
	"testing"
)

func TestRenderComposeCopiesVolumeLabelsToDriverOpts(t *testing.T) {
	in := []byte(`version: "3.8"
services:
  app:
    image: busybox
    volumes:
      - data:/data
volumes:
  data:
    driver: css
    labels:
      cs.mode: shared
      cs.write: multi
      cs.engine: sqlite
      other: keep
    driver_opts:
      cs.write: single
`)
	out, err := RenderComposeBytes(in)
	if err != nil {
		t.Fatal(err)
	}
	s := string(out)
	for _, want := range []string{"driver_opts:", "cs.mode: shared", "cs.write: single", "cs.engine: sqlite"} {
		if !strings.Contains(s, want) {
			t.Fatalf("rendered compose missing %q:\n%s", want, s)
		}
	}
	if strings.Contains(s, "cs.write: multi\n") && !strings.Contains(s, "labels:") {
		t.Fatalf("driver_opts should not be overwritten by label value:\n%s", s)
	}
}

func TestRenderComposeSupportsSequenceLabels(t *testing.T) {
	in := []byte(`volumes:
  data:
    labels:
      - cs.mode=shared
      - cs.crypt=false
`)
	out, err := RenderComposeBytes(in)
	if err != nil {
		t.Fatal(err)
	}
	s := string(out)
	for _, want := range []string{"cs.mode: shared", "cs.crypt: \"false\""} {
		if !strings.Contains(s, want) {
			t.Fatalf("rendered compose missing %q:\n%s", want, s)
		}
	}
}

func TestRenderComposeRejectsFlushLabel(t *testing.T) {
	_, err := RenderComposeBytes([]byte(`volumes:
  data:
    labels:
      flush: "true"
`))
	if err == nil || !strings.Contains(err.Error(), "flush") {
		t.Fatalf("expected flush label rejection, got %v", err)
	}
}
