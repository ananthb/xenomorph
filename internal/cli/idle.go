package cli

import (
	"github.com/ananthb/xmorph/internal/postpivot"
	"github.com/spf13/cobra"
)

// newIdleCmd exposes "do nothing, stay alive" as a real program rather than a
// pivot mode.
//
// A remote rescue pivot has no program to run: the point is to reach the box
// over SSH while its disk is free. Something still has to occupy the
// entrypoint, because when the entrypoint exits there is no init left and
// xmorph reboots into the on-disk OS.
//
// `sleep infinity` fills that role on a normal system but needs coreutils, and
// a bare shell exits immediately once detached. xmorph copies its own binary
// into every pivoted rootfs, so this subcommand is always available no matter
// how minimal the image — alpine, busybox, distroless alike:
//
//	xmorph pivot --entrypoint /usr/local/bin/xmorph --cmd idle --ssh.enable
func newIdleCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "idle",
		Short: "Block until signalled, keeping a pivoted system up and reachable",
		Long: `idle runs nothing and waits for SIGTERM or SIGINT, reaping orphaned
children while it waits.

It exists to be a pivot's entrypoint when the pivot's purpose is access rather
than execution. xmorph places its own binary at ` + postpivot.BinaryPath + ` in
the new rootfs, so this works in images that ship no shell and no coreutils.`,
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			postpivot.ServeUntilSignal()
			return nil
		},
	}
}
