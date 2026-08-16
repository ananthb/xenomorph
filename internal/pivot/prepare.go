package pivot

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// PrepareOptions controls Prepare. Mirrors src/pivot/prepare.zig.
type PrepareOptions struct {
	NewRoot string
	// SkipVerify skips the "looks like a rootfs" sanity check. M2's
	// builder already verifies, so the orchestrator passes true here.
	SkipVerify bool
	// CreateNamespace = true triggers unshare(CLONE_NEWNS). The
	// `runPivot` orchestrator does this elsewhere (so a thread can be
	// locked first); --contain mode calls Prepare with this true.
	CreateNamespace bool
}

// Prepare sets up everything needed before pivot_root: optional
// namespace creation, verification, essential mounts, and self-binding
// of the new root so pivot_root accepts it.
func Prepare(opts PrepareOptions) error {
	if !opts.SkipVerify {
		if err := verifyRoot(opts.NewRoot); err != nil {
			return err
		}
	}
	if opts.CreateNamespace {
		if err := CreateMountNamespace(); err != nil {
			return err
		}
	}
	// Make newRoot a real mount point FIRST, then mount the essentials on
	// top of it. Order matters: a non-recursive self-bind stacks a fresh
	// mount over newRoot that does not carry child mounts, so if the
	// essentials were mounted first they would be shadowed by the self-bind
	// and the pivoted system would come up with no /proc, /sys, or /dev.
	// (This is why pivot_root recipes always bind the new root onto itself
	// before populating it.) pivot_root also requires newRoot to be a mount
	// point, which this satisfies.
	//
	// Skipped when newRoot is already a mount in its own right — the normal
	// case now that the orchestrator mounts a tmpfs there. The self-bind
	// exists only to satisfy pivot_root's "new_root must be a mount point"
	// rule; stacking a second mount to re-satisfy a rule that already holds
	// just adds a mount to unwind.
	alreadyMounted, err := IsMountPoint(opts.NewRoot)
	if err != nil {
		return fmt.Errorf("check whether new root is a mount point: %w", err)
	}
	if !alreadyMounted {
		if err := EnsureMountPoint(opts.NewRoot); err != nil {
			return fmt.Errorf("bind new root onto itself: %w", err)
		}
	}
	if err := MakePrivate(opts.NewRoot); err != nil {
		return fmt.Errorf("make new root private: %w", err)
	}
	if err := SetupEssentials(opts.NewRoot); err != nil {
		return fmt.Errorf("setup essentials: %w", err)
	}
	return nil
}

// verifyRoot checks that newRoot looks like a usable rootfs (bin/ and
// lib/ exist, and at least one of /sbin/init, /bin/sh, /bin/bash is
// present). Mirrors src/pivot/pivot.zig:172-219.
func verifyRoot(newRoot string) error {
	for _, sub := range []string{"bin", "lib"} {
		if _, err := os.Stat(filepath.Join(newRoot, sub)); err != nil {
			return fmt.Errorf("verify: missing %s: %w", sub, err)
		}
	}
	for _, exe := range []string{"sbin/init", "bin/sh", "bin/bash"} {
		if _, err := os.Stat(filepath.Join(newRoot, exe)); err == nil {
			return nil
		}
	}
	return errors.New("verify: no init or shell found in new root")
}
