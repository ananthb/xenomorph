package postpivot

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReadNameservers(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "resolv.conf")
	body := `# comment
; also a comment

nameserver 192.168.1.1
nameserver 2001:4860:4860::8888
search lan
nameserver not-an-ip
options edns0
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	got := readNameservers(path)
	want := []string{"192.168.1.1", "2001:4860:4860::8888"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("index %d: got %q, want %q", i, got[i], want[i])
		}
	}
}

func TestReadNameserversMissingFile(t *testing.T) {
	if got := readNameservers(filepath.Join(t.TempDir(), "nope")); got != nil {
		t.Errorf("missing file should yield nil, got %v", got)
	}
}

func TestFilterRoutableDropsLocalStubs(t *testing.T) {
	// 127.0.0.53 is systemd-resolved's stub and 127.0.0.1 a local dnsmasq.
	// Both are served by daemons that do not survive the pivot.
	got := filterRoutable([]string{"127.0.0.53", "127.0.0.1", "::1", "10.0.0.1"})
	if len(got) != 1 || got[0] != "10.0.0.1" {
		t.Errorf("got %v, want [10.0.0.1]", got)
	}
	if !allLoopback([]string{"127.0.0.53", "::1"}) {
		t.Error("a stub-only resolv.conf must count as unusable")
	}
}

// A rootfs whose resolv.conf points only at a local stub must be rewritten:
// the file looks configured but resolves nothing once the old root is gone.
func TestEnsureResolvConfReplacesStubOnly(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc"), 0o755); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(root, "etc", "resolv.conf")
	if err := os.WriteFile(dst, []byte("nameserver 127.0.0.53\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := EnsureResolvConf(root); err != nil {
		t.Fatalf("EnsureResolvConf: %v", err)
	}
	if servers := readNameservers(dst); allLoopback(servers) {
		t.Errorf("stub survived: %v", servers)
	}
}

// A missing resolv.conf (alpine, busybox, distroless) must be created.
func TestEnsureResolvConfCreatesWhenAbsent(t *testing.T) {
	root := t.TempDir()
	if err := EnsureResolvConf(root); err != nil {
		t.Fatalf("EnsureResolvConf: %v", err)
	}
	dst := filepath.Join(root, "etc", "resolv.conf")
	servers := readNameservers(dst)
	if len(servers) == 0 {
		t.Fatal("no nameservers written")
	}
	if allLoopback(servers) {
		t.Errorf("wrote unusable servers: %v", servers)
	}
	data, err := os.ReadFile(dst)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), "xmorph") {
		t.Error("generated file should say what wrote it")
	}
}

// A usable file from the image is authoritative and must be left alone.
func TestEnsureResolvConfKeepsUsable(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc"), 0o755); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(root, "etc", "resolv.conf")
	want := "nameserver 10.9.8.7\n"
	if err := os.WriteFile(dst, []byte(want), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := EnsureResolvConf(root); err != nil {
		t.Fatalf("EnsureResolvConf: %v", err)
	}
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != want {
		t.Errorf("rewrote a usable file: got %q, want %q", got, want)
	}
}

// A dangling symlink (../run/systemd/resolve/stub-resolv.conf is the common
// one) must be replaced by a real file rather than followed into a directory
// that will not exist after the pivot.
func TestEnsureResolvConfReplacesDanglingSymlink(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "etc"), 0o755); err != nil {
		t.Fatal(err)
	}
	dst := filepath.Join(root, "etc", "resolv.conf")
	if err := os.Symlink("../run/systemd/resolve/stub-resolv.conf", dst); err != nil {
		t.Fatal(err)
	}
	if err := EnsureResolvConf(root); err != nil {
		t.Fatalf("EnsureResolvConf: %v", err)
	}
	fi, err := os.Lstat(dst)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		t.Error("still a symlink")
	}
	if servers := readNameservers(dst); len(servers) == 0 {
		t.Error("no usable nameservers after replacing symlink")
	}
}
