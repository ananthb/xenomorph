package cli

import (
	"strings"
	"testing"

	"github.com/ananthb/xmorph/internal/config"
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
