package postpivot

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestWriteConfigRoundTrip(t *testing.T) {
	dir := t.TempDir()
	cfg := &Config{
		FlushFirewall:          true,
		RebootOnExit:           true,
		Serve:                  true,
		WatchdogTimeoutSeconds: 300,
		KeepOldRoot:            "/mnt/oldroot",
		LogPersistDir:          "/mnt/oldroot/var/log/xmorph",
		SSH: &SSHConfig{
			Port:           22,
			AuthorizedKeys: "ssh-ed25519 AAAA",
		},
		Tailscale: &TSConfig{
			AuthKey: "tskey-auth-abc",
			Args:    "--ssh --hostname=test-xmorph",
		},
		Entrypoint: []string{"/bin/sh"},
	}

	if err := WriteConfig(dir, cfg); err != nil {
		t.Fatalf("WriteConfig: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(dir, ConfigPath))
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	var got Config
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !got.FlushFirewall || !got.RebootOnExit || !got.Serve {
		t.Error("boolean fields lost")
	}
	if got.WatchdogTimeoutSeconds != 300 {
		t.Errorf("WatchdogTimeoutSeconds = %d, want 300", got.WatchdogTimeoutSeconds)
	}
	if got.KeepOldRoot != "/mnt/oldroot" {
		t.Errorf("KeepOldRoot = %q, want /mnt/oldroot", got.KeepOldRoot)
	}
	if got.LogPersistDir != "/mnt/oldroot/var/log/xmorph" {
		t.Errorf("LogPersistDir = %q", got.LogPersistDir)
	}
	if got.SSH == nil || got.SSH.Port != 22 {
		t.Errorf("SSH = %+v", got.SSH)
	}
	if got.Tailscale == nil || got.Tailscale.AuthKey != "tskey-auth-abc" {
		t.Errorf("Tailscale = %+v", got.Tailscale)
	}
	if len(got.Entrypoint) != 1 || got.Entrypoint[0] != "/bin/sh" {
		t.Errorf("Entrypoint = %v", got.Entrypoint)
	}
}

func TestWriteConfigOmitsEmptyOptional(t *testing.T) {
	dir := t.TempDir()
	cfg := &Config{FlushFirewall: true}
	if err := WriteConfig(dir, cfg); err != nil {
		t.Fatalf("WriteConfig: %v", err)
	}
	data, _ := os.ReadFile(filepath.Join(dir, ConfigPath))
	s := string(data)
	for _, omitted := range []string{"\"ssh\"", "\"tailscale\"", "\"entrypoint\"", "\"watchdog_timeout_seconds\"", "\"keep_old_root\"", "\"log_persist_dir\""} {
		if contains := indexOfStr(s, omitted) >= 0; contains {
			t.Errorf("expected %q to be omitted; got %s", omitted, s)
		}
	}
}

func indexOfStr(haystack, needle string) int {
	for i := 0; i+len(needle) <= len(haystack); i++ {
		if haystack[i:i+len(needle)] == needle {
			return i
		}
	}
	return -1
}
