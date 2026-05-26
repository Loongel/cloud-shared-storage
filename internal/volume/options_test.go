package volume

import "testing"

func TestParseOptionsDefaults(t *testing.T) {
	opts, err := ParseOptions(nil)
	if err != nil {
		t.Fatal(err)
	}
	if opts.Mode != "private" || opts.Write != "single" || opts.Engine != "auto" || !opts.Crypt || opts.Backup {
		t.Fatalf("unexpected defaults: %#v", opts)
	}
}

func TestParseDriverOptionsMergesLabelsAndOpts(t *testing.T) {
	opts, err := ParseDriverOptions(
		map[string]string{"cs.write": "single", "cs.crypt": "false", "cs.backup": "true"},
		map[string]string{"cs.mode": "shared", "cs.write": "multi", "cs.engine": "sqlite"},
	)
	if err != nil {
		t.Fatal(err)
	}
	if opts.Mode != "shared" || opts.Write != "single" || opts.Engine != "sqlite" || opts.Crypt || !opts.Backup {
		t.Fatalf("unexpected merged options: %#v", opts)
	}
}

func TestParseDriverOptionsRejectsBadBackup(t *testing.T) {
	for _, value := range []string{"sometimes", "1", "0", "yes", "no", "on", "off"} {
		_, err := ParseDriverOptions(map[string]string{"cs.backup": value}, nil)
		if err == nil {
			t.Fatalf("expected cs.backup=%q to be rejected", value)
		}
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
