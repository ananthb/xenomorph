package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/ananthb/xmorph/internal/config"
	"github.com/ananthb/xmorph/internal/passphrase"
	"github.com/ananthb/xmorph/internal/postpivot"
)

// The last line of defence before anything destructive happens. A bare shell
// detached from a terminal exits the instant it reads stdin, so pivoting into
// one gives an operator a reboot loop instead of the machine they asked for.
// Catching that here costs nothing: the old root is still mounted and the
// pivot has not started.
//
// go test runs with stdin on /dev/null, which is exactly the detached case
// these tests are about. The converse — a real terminal, where a shell is a
// perfectly sensible entrypoint — cannot be exercised without allocating a
// pty, and is left to the --contain path below.
func TestCheckEntrypointSurvivesDetach(t *testing.T) {
	for _, tc := range []struct {
		name       string
		entrypoint string
		contain    bool
		wantErr    bool
	}{
		{name: "sh", entrypoint: "/bin/sh", wantErr: true},
		{name: "bash", entrypoint: "/bin/bash", wantErr: true},
		{name: "busybox", entrypoint: "/bin/busybox", wantErr: true},
		{name: "absolute path is not what matters", entrypoint: "/usr/local/bin/ash", wantErr: true},
		{name: "a real program is fine", entrypoint: "/usr/local/bin/xmorph"},
		{name: "so is an init", entrypoint: "/sbin/init"},
		// --contain keeps the caller's terminal and never leaves the machine
		// without userspace, so a shell there is the normal case.
		{name: "contain permits a shell", entrypoint: "/bin/sh", contain: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := checkEntrypointSurvivesDetach(
				&config.Config{Contain: tc.contain}, tc.entrypoint)
			if tc.wantErr != (err != nil) {
				t.Fatalf("checkEntrypointSurvivesDetach(%q, contain=%v) = %v, wantErr %v",
					tc.entrypoint, tc.contain, err, tc.wantErr)
			}
		})
	}
}

// An error that only says no is a support ticket. This one has to name the way
// forward, because the person reading it is usually mid-rescue on a machine
// they cannot walk over to.
func TestEntrypointRefusalNamesTheFix(t *testing.T) {
	err := checkEntrypointSurvivesDetach(&config.Config{}, "/bin/sh")
	if err == nil {
		t.Fatal("want a refusal for a detached shell")
	}
	for _, want := range []string{"--cmd idle", "--command"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("refusal does not mention %q: %v", want, err)
		}
	}
}

// --ssh.enable with no credentials produced a machine that pivoted, stayed up,
// and could not be logged into: sshd logged "no auth method configured" to a
// console nobody was reading and never bound the port. The VM test found it.
// Now the missing credential is invented rather than demanded.
func TestEnsureSSHUsable(t *testing.T) {
	enabled := true
	disabled := false
	for _, tc := range []struct {
		name          string
		cfg           config.Config
		wantGenerated bool
		wantPassword  string // "" means "whatever was generated"
	}{
		{name: "ssh off", cfg: config.Config{}},
		{name: "ssh explicitly off", cfg: config.Config{SSHEnable: &disabled}},
		{
			name:          "enabled with nothing to authenticate with",
			cfg:           config.Config{SSHEnable: &enabled},
			wantGenerated: true,
		},
		{
			name:         "operator password is left alone",
			cfg:          config.Config{SSHEnable: &enabled, SSHPassword: "hunter2"},
			wantPassword: "hunter2",
		},
		{
			// Keys are enough on their own; generating a password here would
			// weaken a setup that deliberately has no password to guess.
			name: "authorized keys, no password invented",
			cfg:  config.Config{SSHEnable: &enabled, SSHAuthorizedKeys: "ssh-ed25519 AAAA"},
		},
		// SSHEnabled() is implied by any other ssh.* flag, so this is on too.
		{
			name:         "implied by password alone",
			cfg:          config.Config{SSHPassword: "hunter2"},
			wantPassword: "hunter2",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := ensureSSHUsable(&tc.cfg)
			if err != nil {
				t.Fatalf("ensureSSHUsable() error: %v", err)
			}
			if tc.wantGenerated != (got != "") {
				t.Fatalf("ensureSSHUsable() = %q, wantGenerated %v", got, tc.wantGenerated)
			}
			if tc.cfg.SSHPasswordGenerated != tc.wantGenerated {
				t.Errorf("SSHPasswordGenerated = %v, want %v",
					tc.cfg.SSHPasswordGenerated, tc.wantGenerated)
			}
			if !tc.wantGenerated {
				if tc.cfg.SSHPassword != tc.wantPassword {
					t.Errorf("SSHPassword = %q, want %q", tc.cfg.SSHPassword, tc.wantPassword)
				}
				return
			}
			// The generated password has to reach the post-pivot config,
			// which reads it from cfg and not from the return value.
			if tc.cfg.SSHPassword != got {
				t.Errorf("cfg.SSHPassword = %q, generated %q", tc.cfg.SSHPassword, got)
			}
			if n := strings.Count(got, "-") + 1; n != passphrase.DefaultWords {
				t.Errorf("generated %q, want %d hyphenated words", got, passphrase.DefaultWords)
			}
		})
	}
}

// The whole point of generating a password is that someone can read it. A
// banner that prints everything except the password would pass every test
// above.
func TestAnnounceSSHPasswordShowsThePassword(t *testing.T) {
	var buf bytes.Buffer
	postpivot.AnnounceSSHPassword(&buf, "swan-pesky-tofu", 2222)
	out := buf.String()
	if !strings.Contains(out, "swan-pesky-tofu") {
		t.Errorf("banner omits the password: %s", out)
	}
	if !strings.Contains(out, "2222") {
		t.Errorf("banner omits the port an operator has to connect to: %s", out)
	}
}

// An operator-supplied password must never be echoed to a console or into the
// persistent log; only one we generated is ours to print.
func TestOperatorPasswordIsNotMarkedGenerated(t *testing.T) {
	enabled := true
	cfg := config.Config{SSHEnable: &enabled, SSHPassword: "reused-elsewhere"}
	if _, err := ensureSSHUsable(&cfg); err != nil {
		t.Fatalf("ensureSSHUsable() error: %v", err)
	}
	pc := buildPostpivotConfig(&cfg, "/bin/true", nil)
	if pc.SSH == nil {
		t.Fatal("post-pivot config has no SSH section")
	}
	if pc.SSH.PasswordGenerated {
		t.Error("an operator-supplied password is flagged as generated; it would be printed")
	}
	if pc.SSH.Password != "reused-elsewhere" {
		t.Errorf("SSH password = %q, want the one the operator gave", pc.SSH.Password)
	}
}

// ...and the generated one must be flagged, or the post-pivot console never
// shows it and the machine is unreachable again for a different reason.
func TestGeneratedPasswordReachesPostPivotConfig(t *testing.T) {
	enabled := true
	cfg := config.Config{SSHEnable: &enabled}
	got, err := ensureSSHUsable(&cfg)
	if err != nil {
		t.Fatalf("ensureSSHUsable() error: %v", err)
	}
	pc := buildPostpivotConfig(&cfg, "/bin/true", nil)
	if pc.SSH == nil {
		t.Fatal("post-pivot config has no SSH section")
	}
	if !pc.SSH.PasswordGenerated {
		t.Error("generated password is not flagged; it would never be printed post-pivot")
	}
	if pc.SSH.Password != got {
		t.Errorf("SSH password = %q, generated %q", pc.SSH.Password, got)
	}
	if pc.SSH.Port != 22 {
		t.Errorf("SSH port = %d, want the default 22", pc.SSH.Port)
	}
}
