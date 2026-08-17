// Package cli defines the cobra command tree.
//
// The runtime entrypoint cmd/xmorph/main.go branches on os.Args[1] == "--init"
// before invoking cobra — that's the re-exec path for post-pivot init.
// Everything else routes through this package.
package cli

import (
	"fmt"
	"io"
	"log/slog"
	"log/syslog"
	"os"

	xlog "github.com/ananthb/xmorph/internal/log"

	"github.com/ananthb/xmorph/internal/helpers"
	"github.com/spf13/cobra"
)

// LogHandler is the package-global slog.Handler for the binary. main()
// installs it before invoking cobra; runPivot reaches in to flush the
// in-memory buffer just before pivot_root.
var LogHandler *xlog.Handler

// InstallLogger creates the xmorph log handler at the given level,
// sets it as slog's default, and stashes a reference in LogHandler so
// the pivot path can flush the buffer pre-pivot.
func InstallLogger(level slog.Level, colors bool) {
	LogHandler = xlog.NewHandler(os.Stderr, level, colors)
	slog.SetDefault(slog.New(LogHandler))
	attachSystemLogSink(LogHandler)
}

// attachSystemLogSink wires xmorph's log into the host's system log. When
// journald is running it already captures our stderr (systemd's default
// StandardError=journal), so we rely on that and add nothing. Otherwise we
// connect to syslog (/dev/log) as an additional sink. Best-effort: a failure
// to reach syslog just means no system-log copy.
func attachSystemLogSink(h *xlog.Handler) {
	if journaldPresent() {
		return
	}
	if w, err := syslog.New(syslog.LOG_INFO|syslog.LOG_DAEMON, "xmorph"); err == nil {
		h.AddSink(w)
	}
}

// journaldPresent reports whether systemd-journald is running, in which case
// our stderr is captured by the journal and no explicit sink is needed.
func journaldPresent() bool {
	for _, p := range []string{"/run/systemd/journal/socket", "/run/systemd/journal/stdout"} {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}

// NewRootCmd builds the top-level `xmorph` command with `pivot`, `build`,
// and `version` subcommands. Output streams default to the cobra
// command's own out/err; pass through for testing.
func NewRootCmd(stdout, stderr io.Writer) *cobra.Command {
	root := &cobra.Command{
		Use:   "xmorph",
		Short: "Replace the running Linux rootfs with an in-memory rootfs from OCI images",
		Long: `xmorph replaces a running Linux rootfs with a new in-memory rootfs
built from OCI images and/or rootfs tarballs, by way of pivot_root(2).
It coordinates with systemd/openrc/sysvinit to stop services first and
supports unattended operation over Tailscale (in-process via tsnet).`,
		Version:       helpers.Version,
		SilenceUsage:  true,
		SilenceErrors: false,
		PersistentPreRun: func(cmd *cobra.Command, _ []string) {
			if v, _ := cmd.Flags().GetBool("verbose"); v {
				if LogHandler != nil {
					LogHandler.SetLevel(slog.LevelDebug)
				}
			}
		},
	}
	root.SetVersionTemplate("xmorph {{.Version}}\n")
	if stdout != nil {
		root.SetOut(stdout)
	}
	if stderr != nil {
		root.SetErr(stderr)
	}

	// Zig used -V for --version and -v for --verbose (per-subcommand).
	// Register --version with -V BEFORE adding subcommands so cobra's
	// InitDefaultVersionFlag sees an existing flag and leaves it alone.
	root.Flags().BoolP("version", "V", false, "print version and exit")

	root.AddCommand(newPivotCmd(), newBuildCmd(), newIdleCmd(), newVersionCmd())
	return root
}

func newVersionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print version and exit",
		Run: func(cmd *cobra.Command, _ []string) {
			fmt.Fprintf(cmd.OutOrStdout(), "xmorph %s\n", helpers.Version)
		},
	}
}
