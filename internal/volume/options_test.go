package volume

import "testing"

func TestParseOptionsDefaults(t *testing.T) {
	opts, err := ParseOptions(nil)
	if err != nil {
		t.Fatal(err)
	}
	if opts.Mode != "private" || opts.Write != "single" || opts.Engine != "auto" || !opts.Crypt || opts.Backup != "none" {
		t.Fatalf("unexpected defaults: %#v", opts)
	}
}

func TestParseDriverOptionsMergesLabelsAndOpts(t *testing.T) {
	opts, err := ParseDriverOptions(
		map[string]string{"cs.write": "single", "cs.crypt": "false"},
		map[string]string{"cs.mode": "shared", "cs.write": "multi", "cs.engine": "sqlite"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if opts.Mode != "shared" || opts.Write != "single" || opts.Engine != "sqlite" || opts.Crypt {
		t.Fatalf("unexpected merged options: %#v", opts)
	}
}

func TestParseDriverOptionsRejectsFlushInLabels(t *testing.T) {
	_, err := ParseDriverOptions(nil, map[string]string{"flush": "true"})
	if err == nil {
		t.Fatal("expected flush label to be rejected")
	}
}

func TestParseOptionsRejectsPrivateMulti(t *testing.T) {
	_, err := ParseOptions(map[string]string{"cs.mode": "private", "cs.write": "multi"})
	if err == nil {
		t.Fatal("expected private+multi to be rejected")
	}
}
