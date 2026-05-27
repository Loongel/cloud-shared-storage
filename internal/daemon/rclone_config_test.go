package daemon

import (
	"strings"
	"testing"
)

func TestRcloneMountArgsUseRuntimeBearerHeader(t *testing.T) {
	args, err := (RcloneMountSpec{
		ConfigPath:      "/tmp/rclone.conf",
		RemoteName:      "vol.1",
		Mountpoint:      "/mnt/vol",
		CacheDir:        "/cache",
		Token:           "jwt-token",
		VFSWriteBack:    "30s",
		VFSCacheMaxSize: "10G",
	}).Args()
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(args, "\x00")
	if !strings.Contains(joined, "Authorization: Bearer jwt-token") {
		t.Fatalf("missing bearer header in args: %#v", args)
	}
	for _, want := range []string{"--cache-dir\x00/cache", "--vfs-write-back\x0030s", "--vfs-cache-max-size\x0010G"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing %q in args %#v", want, args)
		}
	}
	if strings.Contains(joined, "vol.1:") || !strings.Contains(joined, "vol_1:") {
		t.Fatalf("remote name was not sanitized: %#v", args)
	}
}

func TestEncryptedRealtimeRcloneUsesDecryptedGocryptfsCacheView(t *testing.T) {
	root := t.TempDir()
	s := &Server{cfg: Config{RootDir: root}}
	layout := s.layout("vol")
	args, err := (RcloneMountSpec{
		ConfigPath: "/tmp/rclone.conf",
		RemoteName: "vol",
		Mountpoint: layout.Mountpoint,
		CacheDir:   layout.Cache,
		Token:      "jwt-token",
	}).Args()
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(args, "\x00")
	if !strings.Contains(joined, "--cache-dir\x00"+layout.Cache) {
		t.Fatalf("rclone must use the decrypted gocryptfs cache mount as cache-dir: %#v", args)
	}
	if strings.Contains(joined, layout.Cipher) {
		t.Fatalf("rclone must not read/write the physical cipher directory: %#v", args)
	}
}

func TestRcloneMountArgsEnableRC(t *testing.T) {
	args, err := (RcloneMountSpec{
		ConfigPath: "/tmp/rclone.conf",
		RemoteName: "vol",
		Mountpoint: "/mnt/vol",
		Token:      "jwt-token",
		RCAddr:     "http://127.0.0.1:5572",
		RCUser:     "u",
		RCPassword: "p",
	}).Args()
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(args, "\x00")
	for _, want := range []string{"--rc", "--rc-addr\x00127.0.0.1:5572", "--rc-user\x00u", "--rc-pass\x00p"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing %q in args %#v", want, args)
		}
	}
}
