package postpivot

import (
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// These tests cover the decision that turned a stumble into a machine needing
// physical access: what the supervisor does when the entrypoint goes away.
//
// The pivot_root syscall was never the problem. It worked perfectly on the
// machine that had to be power-cycled — the kernel came up on the new rootfs,
// the entrypoint exited a moment later, and the supervisor returned, leaving a
// running kernel with no userspace on it. It answered ICMP the entire time.
//
// That failure lives here, in a few branches of plain Go, so it is checked
// here — on every push, in a second, on any platform. The VM tests in
// nix/tests/lifecycle.nix assert the same properties end-to-end; these are the
// ones that will still be running in a year.

// captureReboot swaps the reboot hook for the duration of a test and reports
// whether it fired.
func captureReboot(t *testing.T) *atomic.Bool {
	t.Helper()
	var fired atomic.Bool
	prev := rebootHook
	rebootHook = func(string) { fired.Store(true) }
	t.Cleanup(func() { rebootHook = prev })
	return &fired
}

// A clean exit is the dangerous one. The image default entrypoint is a shell;
// detached, its stdin is /dev/null, it reads EOF and exits 0 immediately. The
// original code rebooted only on failure, so status 0 — the likeliest outcome
// of all — was the one case that bricked the box.
func TestSuperviseRebootsOnCleanExit(t *testing.T) {
	fired := captureReboot(t)

	code, err := Supervise(SuperviseOptions{
		Argv:         []string{"/bin/sh", "-c", "exit 0"},
		RebootOnExit: true,
	})
	if err != nil {
		t.Fatalf("Supervise: %v", err)
	}
	if code != 0 {
		t.Errorf("exit code = %d, want 0", code)
	}
	if !fired.Load() {
		t.Error("entrypoint exited 0 and no reboot was triggered: " +
			"that leaves a running kernel with no userspace")
	}
}

func TestSuperviseRebootsOnFailedExit(t *testing.T) {
	fired := captureReboot(t)

	code, err := Supervise(SuperviseOptions{
		Argv:         []string{"/bin/sh", "-c", "exit 3"},
		RebootOnExit: true,
	})
	if err != nil {
		t.Fatalf("Supervise: %v", err)
	}
	if code != 3 {
		t.Errorf("exit code = %d, want 3", code)
	}
	if !fired.Load() {
		t.Error("entrypoint exited 3 and no reboot was triggered")
	}
}

// --contain and the unit tests above run Supervise on a machine that is not
// pivoted, where rebooting would be spectacularly wrong. The flag has to be
// honoured in both directions.
func TestSuperviseHonoursRebootOnExitFalse(t *testing.T) {
	fired := captureReboot(t)

	if _, err := Supervise(SuperviseOptions{
		Argv:         []string{"/bin/sh", "-c", "exit 0"},
		RebootOnExit: false,
	}); err != nil {
		t.Fatalf("Supervise: %v", err)
	}
	if fired.Load() {
		t.Error("rebooted with RebootOnExit false")
	}
}

// An entrypoint that cannot be exec'd must not be mistaken for one that ran
// and exited: the machine never got the userspace it was promised, so it still
// has to go back to the OS on disk.
func TestSuperviseMissingEntrypoint(t *testing.T) {
	code, err := Supervise(SuperviseOptions{
		Argv:         []string{"/nonexistent/xmorph-test-entrypoint"},
		RebootOnExit: true,
	})
	if err == nil {
		t.Fatal("want an error for a missing entrypoint, got nil")
	}
	if code != 127 {
		t.Errorf("exit code = %d, want 127", code)
	}
}

// idle is the other half of the fix: the entrypoint for a pivot whose purpose
// is access rather than execution. It has to hold the box up indefinitely, and
// in particular it must not mistake a passing child for a reason to quit — as
// the supervisor it inherits every orphan on the machine.
func TestServeUntilSignalBlocksUntilSignalled(t *testing.T) {
	// Claim SIGTERM for the process before anything sends one. Signal
	// dispositions are process-wide, so this also guarantees the test does
	// not die if our TERM lands before ServeUntilSignal has registered.
	guard := make(chan os.Signal, 4)
	signal.Notify(guard, syscall.SIGTERM)
	defer signal.Stop(guard)

	done := make(chan int, 1)
	go func() { done <- ServeUntilSignal() }()

	// A child that comes and goes raises SIGCHLD. Waking on that and
	// returning would tear down the SSH server the operator is connected to.
	child := exitingChild(t)
	select {
	case <-done:
		t.Fatal("ServeUntilSignal returned when a child exited; " +
			"it must only stop on TERM/INT")
	case <-time.After(500 * time.Millisecond):
	}
	_ = child

	// Now the real stop condition. Retry: there is no way to observe the
	// moment ServeUntilSignal installs its handler, and a TERM delivered
	// before then is absorbed by the guard above.
	deadline := time.After(10 * time.Second)
	tick := time.NewTicker(50 * time.Millisecond)
	defer tick.Stop()
	for {
		if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
			t.Fatalf("kill: %v", err)
		}
		select {
		case code := <-done:
			if code != 0 {
				t.Errorf("ServeUntilSignal returned %d, want 0", code)
			}
			return
		case <-deadline:
			t.Fatal("ServeUntilSignal did not return after SIGTERM")
		case <-tick.C:
		}
	}
}

// exitingChild starts and immediately loses a child process, producing the
// SIGCHLD that ServeUntilSignal must ignore.
func exitingChild(t *testing.T) int {
	t.Helper()
	pid, err := syscall.ForkExec("/bin/sh", []string{"/bin/sh", "-c", "exit 0"},
		&syscall.ProcAttr{Files: []uintptr{0, 1, 2}})
	if err != nil {
		t.Skipf("fork/exec unavailable: %v", err)
	}
	return pid
}
