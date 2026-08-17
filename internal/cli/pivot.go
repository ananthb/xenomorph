package cli

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"syscall"
	"time"

	"github.com/ananthb/xmorph/internal/config"
	"github.com/ananthb/xmorph/internal/helpers"
	"github.com/ananthb/xmorph/internal/initsys"
	"github.com/ananthb/xmorph/internal/oci"
	"github.com/ananthb/xmorph/internal/pivot"
	"github.com/ananthb/xmorph/internal/postpivot"
	"github.com/ananthb/xmorph/internal/process"
	"github.com/ananthb/xmorph/internal/rootfs"
	"github.com/ananthb/xmorph/internal/tsnetauth"
	"github.com/spf13/cobra"
	"golang.org/x/sys/unix"
)

// errNotImplemented is retained for the not-yet-wired tsnet path (M6).
var errNotImplemented = errors.New("not implemented in this milestone")

func newPivotCmd() *cobra.Command {
	cfg := config.New()

	cmd := &cobra.Command{
		Use:   "pivot [-- args...]",
		Short: "Execute pivot_root into a new rootfs built from OCI images",
		Long: `pivot builds a rootfs from the configured layers, coordinates with
the running init system to stop services, then calls pivot_root(2) to atomically
swap the root filesystem. The old root is kept at /mnt/oldroot by default.

Anything after a literal "--" is appended to --command, useful for passing
arguments that would otherwise be interpreted as flags.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg.Normalize(cmd.Flags(), args, nil)
			if err := cfg.Validate(cmd.ErrOrStderr()); err != nil {
				return err
			}
			return runPivot(cmd.Context(), &cfg, cmd.OutOrStdout())
		},
	}
	config.BindPivot(cmd.Flags(), &cfg)
	return cmd
}

// runPivot is the full host-side pivot pipeline:
//
//  1. --dry-run        → print plan, return.
//  2. --contain        → build rootfs, run inside mount+PID namespace.
//  3. Detach: on systemd, relocate into a transient scope so the launching
//     session/service can't reap us; warn if over SSH and undetached.
//  4. Build rootfs.
//  5. Resolve entrypoint from cfg + merged ImageConfig.
//  6. Write /etc/xmorph-init.json + copy binary to new rootfs.
//  7. Init coordination (unless --no-init-coord / --systemd-mode).
//  8. Process termination (unless --systemd-mode).
//  9. Pivot mount sequence + pivot_root.
//
// 10. Exec into the new rootfs's /usr/local/bin/xmorph --init <argv>.
//
// At any failure before step 9 we abort cleanly; after step 9 the host
// is past the point of return.
func runPivot(ctx context.Context, cfg *config.Config, stdout interface {
	Write(p []byte) (n int, err error)
}) error {
	if cfg.DryRun {
		printDryRun(stdout, cfg)
		return nil
	}

	if cfg.Contain {
		return runContain(cfg)
	}

	if os.Geteuid() != 0 {
		return errors.New("pivot requires root (CAP_SYS_ADMIN for namespace + pivot_root)")
	}

	// --force skips the interactive confirmation.
	if !cfg.Force {
		fmt.Fprintln(os.Stderr, "Refusing to pivot without --force")
		return errors.New("confirmation required (--force)")
	}

	slog.Info("pivot starting", "layers", len(cfg.Layers), "work_dir", cfg.WorkDir,
		"systemd_mode", cfg.SystemdMode, "watchdog", cfg.WatchdogTimeout)

	// Attach the on-disk log sink now so everything below is captured there
	// too; the same buffer is flushed into the new rootfs before pivot_root.
	if cfg.LogDir != "" && LogHandler != nil {
		logFile := filepath.Join(cfg.LogDir, "xmorph.log")
		if err := os.MkdirAll(cfg.LogDir, 0o755); err != nil {
			slog.Warn("log-dir mkdir failed; file logging disabled", "dir", cfg.LogDir, "err", err)
		} else if f, err := os.OpenFile(logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644); err != nil {
			slog.Warn("log-dir open failed; file logging disabled", "path", logFile, "err", err)
		} else {
			LogHandler.AddSink(f)
			slog.Info("file logging enabled", "path", logFile)
		}
	}

	// Detach from the launching session so the pivot outlives it. On
	// systemd we ask systemd to adopt us into a transient scope — like
	// `systemd-run --scope`, but for the running process — which moves us
	// out of a run0/systemd-run .service or SSH session scope that would
	// otherwise SIGKILL us on teardown. No fork, no exec. Skipped under
	// --systemd-mode: there we're already a managed unit.
	detached := false
	if !cfg.SystemdMode && initsys.Detect() == initsys.Systemd {
		if scope, err := initsys.RelocateToTransientScope("xmorph pivot into a new in-memory rootfs"); err != nil {
			slog.Warn("could not relocate into a transient systemd scope; a mid-pivot disconnect may kill xmorph", "err", err)
		} else {
			detached = true
			slog.Info("relocated into transient systemd scope", "unit", scope)
		}
	}

	// Over SSH the pivot severs this connection. If we couldn't detach
	// (non-systemd host, or the relocation failed), a disconnect during the
	// pivot can take xmorph with it — warn and give a grace window to abort.
	if initsys.RunningOverSSH() {
		if detached {
			slog.Warn("over SSH: this session will drop during the pivot, but xmorph is detached and will continue — reconnect via your entrypoint's access (e.g. Tailscale/SSH in the new rootfs)")
		} else {
			const grace = 10 * time.Second
			slog.Warn("over SSH and NOT detached from this session — if you disconnect during the pivot xmorph may be killed; prefer --systemd-mode under `systemd-run`. Continuing shortly; press Ctrl-C to abort", "grace", grace)
			time.Sleep(grace)
		}
	}

	// From here on a dropped controlling session must not take xmorph with
	// it. The transient-scope relocation above only fixes cgroup reaping; it
	// does NOT detach the controlling TTY, so when the pivot severs the SSH
	// connection (or init coordination stops sshd) the kernel delivers SIGHUP
	// to this process group, whose default disposition is fatal. SIGPIPE is
	// the same story for a slog write to a stderr fd whose reader just died.
	// Ignore both now — we have already committed to proceeding (the SSH
	// grace window above was the last chance to abort). SIGINT/SIGTERM are
	// left alone until the destructive steps below so local Ctrl-C still
	// aborts a long rootfs build.
	signal.Ignore(syscall.SIGHUP, syscall.SIGPIPE)

	if err := os.MkdirAll(cfg.WorkDir, 0o755); err != nil {
		return fmt.Errorf("create work dir: %w", err)
	}

	slog.Info("building rootfs", "layers", len(cfg.Layers), "target", cfg.WorkDir)
	result, err := rootfs.Build(cfg.Layers, cfg.WorkDir)
	if err != nil {
		return fmt.Errorf("build rootfs: %w", err)
	}
	slog.Info("rootfs built", "layers", result.LayerCount)

	entrypoint, entryArgs, _ := resolveEntrypoint(cfg, result.Config)
	slog.Info("entrypoint resolved", "entrypoint", entrypoint, "args", len(entryArgs))

	// Write the postpivot config (read back by `xmorph --init`) and copy
	// the running binary into the new rootfs.
	pivotConfig := buildPostpivotConfig(cfg, entrypoint, entryArgs)
	if err := postpivot.WriteConfig(cfg.WorkDir, pivotConfig); err != nil {
		return fmt.Errorf("write postpivot config: %w", err)
	}
	if err := postpivot.CopyBinary(cfg.WorkDir); err != nil {
		return fmt.Errorf("copy binary: %w", err)
	}
	// Do this while the old root is still mounted — /etc/resolv.conf has to be
	// read from it, and after the pivot the resolver it names is gone anyway.
	if err := postpivot.EnsureResolvConf(cfg.WorkDir); err != nil {
		return fmt.Errorf("prepare resolv.conf: %w", err)
	}
	slog.Info("staged post-pivot config and binary", "work_dir", cfg.WorkDir)

	// Pre-pivot tailscale auth: validate the authkey against the live
	// network NOW, while the old OS is still working. On success the
	// state lands in {rootfs}/var/lib/tailscale, ready for the
	// post-pivot supervisor to re-open. On auth failure we abort
	// before destroying the running OS. Mirrors src/cmd/pivot.zig:316-335.
	if cfg.TailscaleEnabled() {
		ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		err := tsnetauth.PreAuth(ctx, tsnetauth.PreAuthOptions{
			RootfsPath: cfg.WorkDir,
			AuthKey:    cfg.TailscaleAuthkey,
			Hostname:   helpers.TailscaleHostname(cfg),
			ControlURL: cfg.TailscaleServer,
		})
		if err != nil {
			return fmt.Errorf("pre-pivot tailscale auth failed; aborting to keep the running OS alive: %w", err)
		}
		slog.Info("tailscale pre-pivot auth ok")
	}

	// Check watchdog now, before we pivot. Same reasoning as tsnet
	// preauth: fail while the old OS is still alive.
	if cfg.WatchdogTimeout > 0 {
		if err := postpivot.EnsureWatchdogAvailable(); err != nil {
			return fmt.Errorf("--watchdog-timeout requested but %w — load softdog or drop the flag", err)
		}
		slog.Info("watchdog pre-pivot check ok")
	}

	// Persistent log dir pre-check. Resolved path lives on the pre-pivot
	// root today; post-pivot it moves under KeepOldRoot.
	if cfg.LogPersistPath != "" {
		if cfg.KeepOldRoot == "" {
			return fmt.Errorf("--log-persist-path requires --keep-old-root (need the old root mounted post-pivot)")
		}
		prePivotDir := filepath.Join("/", cfg.LogPersistDevice, cfg.LogPersistPath)
		if err := ensureLogDirWritable(prePivotDir); err != nil {
			return fmt.Errorf("--log-persist-path %s: %w", prePivotDir, err)
		}
		slog.Info("log-persist pre-pivot check ok", "path", prePivotDir)
	}

	// Memory headroom: warn before we commit to the pivot.
	// (sysmem usage will be wired through when M5's RAM telemetry is
	// surfaced via the slog output — for now we just verify the file
	// is readable.)

	// Point of no safe abort: everything below stops services, terminates
	// userspace, and pivots. A stray Ctrl-C or a SIGTERM from a supervising
	// unit here would strand the machine with services down and no new root,
	// so stop honoring them now (SIGHUP/SIGPIPE were already ignored above).
	signal.Ignore(syscall.SIGINT, syscall.SIGTERM)

	if !cfg.SystemdMode {
		if !cfg.NoInitCoord && !initsys.ShouldSkipCoordination() {
			coord := initsys.NewCoordinator(time.Duration(cfg.Timeout) * time.Second)
			slog.Info("coordinating with init system", "kind", coord.Kind)
			if err := coord.TransitionToRescue(); err != nil {
				slog.Warn("transition-to-rescue failed; continuing", "err", err)
			}
			if err := coord.WaitForServicesToStop(); err != nil {
				slog.Warn("wait for services to stop", "err", err)
			}
		}

		slog.Info("terminating non-essential processes")
		_, err := process.Terminate(process.TerminateOptions{
			GracefulTimeout: time.Duration(cfg.Timeout) * time.Second,
			SkipEssential:   true,
		})
		if err != nil {
			slog.Warn("process termination", "err", err)
		}
	} else {
		slog.Info("systemd-mode: skipping init coordination + process termination")
	}

	// Arm the watchdog now, right before the pivot, so the window until the
	// supervisor adopts it (just the mount sequence + exec) is tiny. It's
	// opened here on the host /dev; the fd is inherited across pivot_root and
	// the exec, and pet post-pivot via WatchdogFDEnv. pivot_root keeps the
	// running kernel, so it's the same live watchdog throughout — no softdog,
	// no reopen by path in the pivoted rootfs. (EnsureWatchdogAvailable above
	// already validated it while the old OS was fully alive.)
	var watchdogFile *os.File
	if cfg.WatchdogTimeout > 0 {
		wf, err := postpivot.ArmWatchdogPrePivot(cfg.WatchdogTimeout)
		if err != nil {
			return fmt.Errorf("arm watchdog: %w", err)
		}
		watchdogFile = wf
		// Runs only on an abort before exec (unix.Exec never returns on
		// success): disarm so a box that's staying on the old OS isn't reset.
		defer func() {
			_, _ = watchdogFile.Write([]byte{'V'}) // magic close = disarm
			_ = watchdogFile.Close()
		}()
	}

	// All goroutines below this point share a single OS thread so the
	// new mount namespace is consistent across what we do.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()

	slog.Info("preparing pivot mounts", "new_root", cfg.WorkDir)
	if err := pivot.Prepare(pivot.PrepareOptions{
		NewRoot:         cfg.WorkDir,
		SkipVerify:      true,
		CreateNamespace: true,
	}); err != nil {
		return fmt.Errorf("prepare pivot: %w", err)
	}

	// Pre-create the old-root mount point inside the new rootfs.
	oldRootRel := "mnt/oldroot"
	if err := os.MkdirAll(filepath.Join(cfg.WorkDir, oldRootRel), 0o755); err != nil {
		return fmt.Errorf("create old-root mount point: %w", err)
	}

	// Flush the in-memory log buffer to the new rootfs RIGHT NOW —
	// after pivot_root the old path vanishes from view. Go's heap
	// (anonymous pages) survives the mount-namespace transition, so
	// any logs written AFTER this flush also persist in memory; they
	// just won't reach disk until a later sync from inside the new
	// rootfs. See plan risk #1.
	if LogHandler != nil {
		logPath := filepath.Join(cfg.WorkDir, cfg.LogDir, "xmorph.log")
		if err := LogHandler.FlushBufferTo(logPath); err != nil {
			slog.Warn("flush log buffer", "err", err)
		}
	}

	slog.Info("pivoting root", "new_root", cfg.WorkDir, "old_root", "/"+oldRootRel)
	if err := pivot.PivotRoot(cfg.WorkDir, oldRootRel); err != nil {
		return fmt.Errorf("pivot_root: %w", err)
	}
	slog.Info("pivot_root complete; old root at /" + oldRootRel)

	if cfg.KeepOldRoot == "" {
		slog.Info("unmounting old root")
		if failed, err := pivot.CleanupOldRoot("/" + oldRootRel); err != nil {
			slog.Warn("cleanup old root", "err", err)
		} else if len(failed) > 0 {
			slog.Warn("some old-root mounts did not unmount", "count", len(failed))
		}
	}

	// Exec the post-pivot supervisor: /usr/local/bin/xmorph --init <argv>.
	// Hand the pre-armed watchdog fd across the exec so the supervisor pets
	// the same live device instead of reopening it in the pivoted /dev.
	env := os.Environ()
	if watchdogFile != nil {
		env = append(env, fmt.Sprintf("%s=%d", postpivot.WatchdogFDEnv, watchdogFile.Fd()))
	}
	slog.Info("exec post-pivot supervisor", "binary", postpivot.BinaryPath, "entrypoint", entrypoint)
	supervisorArgv := append([]string{postpivot.BinaryPath, "--init", entrypoint}, entryArgs...)
	if err := unix.Exec(postpivot.BinaryPath, supervisorArgv, env); err != nil {
		return fmt.Errorf("exec post-pivot supervisor: %w", err)
	}
	return nil // unreachable
}

func buildPostpivotConfig(cfg *config.Config, entrypoint string, entryArgs []string) *postpivot.Config {
	pc := &postpivot.Config{
		FlushFirewall:          !cfg.KeepFirewall,
		RebootOnExit:           true,
		Serve:                  serveOnly(cfg),
		WatchdogTimeoutSeconds: int(cfg.WatchdogTimeout / time.Second),
		KeepOldRoot:            cfg.KeepOldRoot,
		Entrypoint:             append([]string{entrypoint}, entryArgs...),
	}
	if cfg.LogPersistPath != "" && cfg.KeepOldRoot != "" {
		pc.LogPersistDir = filepath.Join(cfg.KeepOldRoot, cfg.LogPersistDevice, cfg.LogPersistPath)
	}
	if cfg.SSHEnabled() {
		ssh := &postpivot.SSHConfig{
			Password:       cfg.SSHPassword,
			AuthorizedKeys: cfg.SSHAuthorizedKeys,
		}
		if cfg.SSHPort != nil {
			ssh.Port = int(*cfg.SSHPort)
		} else {
			ssh.Port = 22
		}
		pc.SSH = ssh
	}
	if cfg.TailscaleEnabled() {
		pc.Tailscale = &postpivot.TSConfig{
			AuthKey: cfg.TailscaleAuthkey,
			Args:    cfg.TailscaleArgs,
		}
	}
	return pc
}

// runContain builds the rootfs into cfg.WorkDir, then re-execs the
// entrypoint inside an unshared mount+PID namespace via pivot.Contain.
// No real pivot_root.
func runContain(cfg *config.Config) error {
	if os.Geteuid() != 0 {
		return errors.New("--contain requires root (CAP_SYS_ADMIN for namespace ops)")
	}

	slog.Info("building rootfs for --contain", "layers", len(cfg.Layers), "target", cfg.WorkDir)
	if err := os.RemoveAll(cfg.WorkDir); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("clean work dir: %w", err)
	}
	if err := os.MkdirAll(cfg.WorkDir, 0o755); err != nil {
		return fmt.Errorf("create work dir: %w", err)
	}

	result, err := rootfs.Build(cfg.Layers, cfg.WorkDir)
	if err != nil {
		return fmt.Errorf("build rootfs: %w", err)
	}
	slog.Info("rootfs built", "layers", result.LayerCount)

	entrypoint, entryArgs, env := resolveEntrypoint(cfg, result.Config)
	slog.Info("entering contained shell", "entrypoint", entrypoint, "args", entryArgs)

	return pivot.Contain(pivot.ContainOptions{
		NewRoot:    cfg.WorkDir,
		Entrypoint: entrypoint,
		Args:       entryArgs,
		Env:        env,
	})
}

// ensureLogDirWritable makes dir and confirms we can write into it.
func ensureLogDirWritable(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("mkdir: %w", err)
	}
	probe, err := os.CreateTemp(dir, ".xmorph-probe-")
	if err != nil {
		return fmt.Errorf("write probe: %w", err)
	}
	name := probe.Name()
	probe.Close()
	return os.Remove(name)
}

// serveOnly reports whether this pivot exists to expose SSH/Tailscale rather
// than to run a program: services are enabled and the operator named neither
// an entrypoint nor a command.
//
// The image's own default is deliberately ignored here. Minimal images
// default to a shell (alpine's Cmd is ["/bin/sh"]), and a shell is precisely
// what must not be supervised in this mode — driven over SSH there is no
// terminal, so it reads EOF on stdin and exits before anyone connects,
// taking the SSH server down with it. An operator who genuinely wants a
// program run says so with --command or --entrypoint, and that still works.
func serveOnly(cfg *config.Config) bool {
	if cfg.EntrypointExplicit || len(cfg.Command) > 0 {
		return false
	}
	return cfg.SSHEnabled() || cfg.TailscaleEnabled()
}

// resolveEntrypoint picks the effective entrypoint + args + env from the
// CLI config and the merged ImageConfig. Mirrors src/cmd/pivot.zig:194-236.
func resolveEntrypoint(cfg *config.Config, ic *oci.ImageConfig) (entrypoint string, args, env []string) {
	if cfg.EntrypointExplicit {
		entrypoint = cfg.Entrypoint
		args = cfg.Command
	} else if ic != nil && len(ic.Entrypoint) > 0 {
		entrypoint = ic.Entrypoint[0]
		args = append(append([]string(nil), ic.Entrypoint[1:]...), ic.Cmd...)
	} else if ic != nil && len(ic.Cmd) > 0 {
		entrypoint = ic.Cmd[0]
		args = ic.Cmd[1:]
	} else {
		entrypoint = cfg.Entrypoint // /bin/sh default
		args = cfg.Command
	}
	if ic != nil {
		env = ic.Env
	}
	return
}
