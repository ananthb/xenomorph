package postpivot

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/ananthb/xmorph/internal/tsnetauth"
)

// Run is the entry point for `xmorph --init` after the pivot. Reads
// /etc/xmorph-init.json, ensures device nodes + firewall flush, then
// supervises the entrypoint. argv is the command-line passed to
// xmorph --init <entrypoint> <args...>; if the JSON has its own
// entrypoint+command those take precedence.
//
// Mirrors the lifecycle of src/xenomorph-init.zig:main:
//
//  1. EnsureDeviceNodes
//  2. Load /etc/xmorph-init.json (optional)
//  3. Optional FlushFirewall
//  4. Set up SSH / tailscale env vars (M6)
//  5. Supervise the entrypoint
func Run(argv []string) int {
	EnsureDeviceNodes()

	cfg, err := LoadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "xmorph --init: warning: %v\n", err)
	}
	// The config carries the SSH password and Tailscale auth key; now that
	// it's in memory, remove it from the rootfs so it doesn't linger
	// world-visible for the life of the pivoted system.
	if err := os.Remove(ConfigPath); err != nil && !os.IsNotExist(err) {
		slog.Warn("could not remove init config after load", "path", ConfigPath, "err", err)
	}

	if cfg != nil && cfg.FlushFirewall {
		FlushFirewall()
	}

	var entrypointLog io.Writer
	if cfg != nil && cfg.LogPersistDir != "" {
		if err := os.MkdirAll(cfg.LogPersistDir, 0o755); err != nil {
			slog.Error("log-persist mkdir", "dir", cfg.LogPersistDir, "err", err)
		} else {
			if xf, err := os.OpenFile(filepath.Join(cfg.LogPersistDir, "xmorph.log"), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644); err == nil {
				defer xf.Close()
				slog.SetDefault(slog.New(slog.NewTextHandler(io.MultiWriter(os.Stderr, xf), nil)))
				slog.Info("persistent log opened", "dir", cfg.LogPersistDir)
			} else {
				slog.Error("open xmorph.log", "err", err)
			}
			if ef, err := os.OpenFile(filepath.Join(cfg.LogPersistDir, "entrypoint.log"), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644); err == nil {
				defer ef.Close()
				entrypointLog = ef
			} else {
				slog.Error("open entrypoint.log", "err", err)
			}
		}
	}

	if cfg != nil && cfg.WatchdogTimeoutSeconds > 0 {
		timeout := time.Duration(cfg.WatchdogTimeoutSeconds) * time.Second
		// The watchdog was opened and armed pre-pivot; its fd is inherited
		// here via WatchdogFDEnv. Adopt and pet it — don't reopen
		// /dev/watchdog by path, which the pivoted /dev may not expose.
		if s := os.Getenv(WatchdogFDEnv); s != "" {
			if fd, err := strconv.Atoi(s); err == nil {
				defer AdoptWatchdog(fd, timeout).Close()
			} else {
				slog.Error("watchdog: invalid inherited fd", "value", s, "err", err)
			}
		} else {
			slog.Warn("watchdog: no inherited fd from pre-pivot; not armed post-pivot")
		}
	}

	var tailnet TailnetListener
	if cfg != nil && cfg.Tailscale != nil {
		hostname := hostnameFromArgs(cfg.Tailscale.Args)
		srv, err := tsnetauth.NewPostPivotServer(context.Background(), tsnetauth.PostPivotOptions{
			Hostname: hostname,
		})
		if err != nil {
			slog.Error("tsnet post-pivot", "err", err)
		} else {
			defer srv.Close()
			tailnet = srv
		}
	}

	if cfg != nil && cfg.SSH != nil {
		go func() {
			if err := StartSSHServer(context.Background(), cfg.SSH, tailnet); err != nil {
				slog.Error("sshd", "err", err)
			}
		}()
	}

	// No entrypoint to run: hold the box up and serve SSH. Returning here
	// would leave a kernel with no userspace, so this blocks until signalled.
	if cfg != nil && cfg.Serve {
		return ServeUntilSignal()
	}

	// Decide what to exec. Config-supplied entrypoint+command beats argv.
	var supervised []string
	if cfg != nil && len(cfg.Entrypoint) > 0 {
		supervised = append(supervised, cfg.Entrypoint...)
		supervised = append(supervised, cfg.Command...)
	} else {
		supervised = argv
	}
	if len(supervised) == 0 {
		fmt.Fprintln(os.Stderr, "xmorph --init: no entrypoint")
		return 1
	}

	rebootOnExit := cfg == nil || cfg.RebootOnExit
	var oldRoot string
	if cfg != nil {
		oldRoot = cfg.KeepOldRoot
	}
	code, err := Supervise(SuperviseOptions{
		Argv:         supervised,
		RebootOnExit: rebootOnExit,
		OldRootPath:  oldRoot,
		LogWriter:    entrypointLog,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "xmorph --init: %v\n", err)
		if code == 0 {
			code = 1
		}
	}
	return code
}
