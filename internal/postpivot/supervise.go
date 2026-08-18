package postpivot

import (
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

// lockedWriter serializes concurrent writes to w. os/exec copies the
// child's stdout and stderr on separate goroutines; when both tee into the
// same LogWriter their writes must not race or interleave.
type lockedWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (l *lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.w.Write(p)
}

// SuperviseOptions configures Supervise.
type SuperviseOptions struct {
	// Argv is the entrypoint with its arguments. argv[0] is exec'd.
	Argv []string
	// Env is the environment passed to the entrypoint. Nil = inherit.
	Env []string
	// RebootOnExit: if true, sync the filesystem and trigger
	// LINUX_REBOOT_CMD_RESTART when the entrypoint exits — for ANY exit,
	// including a clean status 0.
	//
	// Post-pivot there is no init left to fall back to: the old root's
	// systemd was torn down before pivot_root, and this supervisor is the
	// only thing keeping userspace alive. When it returns, the box is a
	// running kernel with nothing on it — it still answers ICMP (the kernel
	// does that), so it looks alive from outside while being unreachable and
	// unrecoverable without physical access.
	//
	// A clean exit is the *likely* case, not the exotic one: the default
	// entrypoint is a shell, and a shell whose stdin is /dev/null reads EOF
	// and exits 0 immediately. Rebooting instead returns the machine to the
	// OS on disk, which is always a better end state than bricked-alive.
	RebootOnExit bool
	// OldRootPath is unmounted before reboot; empty skips.
	OldRootPath string
	// LogWriter, if non-nil, tees the child's stdout + stderr.
	LogWriter io.Writer
}

// Supervise spawns Argv as a child process and forwards
// TERM/INT/HUP/USR1/USR2 to it. When the child exits, reaps any other
// orphans, then exits with the child's status (or reboots).
//
// This is the post-pivot equivalent of tini — the M4 xmorph --init
// path calls Supervise after EnsureDeviceNodes + FlushFirewall +
// service setup. Mirrors src/xenomorph-init.zig:217-353.
func Supervise(opts SuperviseOptions) (exitCode int, err error) {
	if len(opts.Argv) == 0 {
		return 1, errors.New("supervise: empty argv")
	}

	cmd := exec.Command(opts.Argv[0], opts.Argv[1:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if opts.LogWriter != nil {
		// Share one locked writer between the two tees so the stdout- and
		// stderr-copy goroutines don't race on LogWriter.
		lw := &lockedWriter{w: opts.LogWriter}
		cmd.Stdout = io.MultiWriter(os.Stdout, lw)
		cmd.Stderr = io.MultiWriter(os.Stderr, lw)
	}
	if opts.Env != nil {
		cmd.Env = opts.Env
	}

	if err := cmd.Start(); err != nil {
		return 127, fmt.Errorf("exec %s: %w", opts.Argv[0], err)
	}

	sigCh := make(chan os.Signal, 8)
	signal.Notify(sigCh,
		syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP,
		syscall.SIGUSR1, syscall.SIGUSR2,
	)
	defer signal.Stop(sigCh)

	doneCh := make(chan error, 1)
	go func() { doneCh <- cmd.Wait() }()

	for {
		select {
		case sig := <-sigCh:
			_ = cmd.Process.Signal(sig)
		case err := <-doneCh:
			signal.Stop(sigCh)
			reapOrphans()
			code := exitStatusFrom(cmd, err)
			if opts.RebootOnExit {
				slog.Warn("entrypoint exited; no userspace left, rebooting into the on-disk OS",
					"code", code)
				rebootHook(opts.OldRootPath)
			}
			return code, nil
		}
	}
}

// ServeUntilSignal blocks until TERM/INT is received, reaping orphans as
// they appear. It is the entrypoint for a pivot whose purpose is to expose
// SSH and Tailscale rather than to run a program.
//
// This exists because the obvious alternative — supervising `/bin/sh` — is
// wrong for a remotely-driven pivot. There is no terminal on the other end,
// so the shell's stdin is /dev/null (or a closed pipe), it reads EOF, and it
// exits before anyone can connect. Telling users to pass `sleep infinity`
// works but makes the tool's headline use case depend on a shell idiom and on
// coreutils being present in the image. Blocking here needs neither: no
// /bin/sh, no sleep, nothing from the image at all.
//
// SIGCHLD is deliberately not a wake-up condition. As the supervisor we
// inherit every orphan on the box, so children will come and go; that is
// not a reason to tear down the SSH server the operator is relying on.
func ServeUntilSignal() int {
	sigCh := make(chan os.Signal, 8)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(sigCh)

	chldCh := make(chan os.Signal, 8)
	signal.Notify(chldCh, syscall.SIGCHLD)
	defer signal.Stop(chldCh)

	slog.Info("serving; no entrypoint to supervise (send SIGTERM to stop)")
	for {
		select {
		case sig := <-sigCh:
			slog.Info("received signal, stopping", "signal", sig)
			reapOrphans()
			return 0
		case <-chldCh:
			reapOrphans()
		}
	}
}

// reapOrphans waits for any remaining children (non-blocking) so the
// kernel doesn't accumulate zombies under us.
func reapOrphans() {
	for {
		var status syscall.WaitStatus
		pid, err := syscall.Wait4(-1, &status, syscall.WNOHANG, nil)
		if pid <= 0 || err != nil {
			return
		}
	}
}

func exitStatusFrom(cmd *exec.Cmd, waitErr error) int {
	if cmd.ProcessState != nil {
		if cmd.ProcessState.Exited() {
			return cmd.ProcessState.ExitCode()
		}
		// Signaled or stopped — surface as 128 + signal number, matching
		// shell conventions and the Zig version (src/xenomorph-init.zig:321-326).
		if ws, ok := cmd.ProcessState.Sys().(syscall.WaitStatus); ok {
			if ws.Signaled() {
				return 128 + int(ws.Signal())
			}
		}
	}
	if waitErr != nil {
		return 1
	}
	return 0
}

// rebootHook is what Supervise calls once it decides the machine has to go
// back to the OS on disk. It is a variable so tests can assert on that
// decision: the real implementation never returns, and a test that reboots
// the machine running it is not a test.
//
// "Did we decide to reboot?" is the whole of the bug this indirection exists
// for. A pivot that leaves a kernel with no userspace needs someone on site
// with a power cable, so the decision has to be checked on every push, not
// only when a VM happens to be available.
var rebootHook = rebootSystem

// rebootSystem sleeps 5s (for log flush), then hands off to the
// platform doReboot.
func rebootSystem(oldRoot string) {
	time.Sleep(5 * time.Second)
	doReboot(oldRoot)
}
