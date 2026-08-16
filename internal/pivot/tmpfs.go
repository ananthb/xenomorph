package pivot

import (
	"fmt"
	"os"
	"path/filepath"

	"golang.org/x/sys/unix"
)

// IsMountPoint reports whether path is itself a mount point, by comparing
// its device number with its parent's. This is the same test `mountpoint(1)`
// makes, and it is cheaper and more robust than scanning /proc/self/mounts
// for a string match.
func IsMountPoint(path string) (bool, error) {
	var st, parent unix.Stat_t
	if err := unix.Lstat(path, &st); err != nil {
		return false, err
	}
	if err := unix.Lstat(filepath.Dir(path), &parent); err != nil {
		return false, err
	}
	return st.Dev != parent.Dev, nil
}

// MountTmpfs mounts a tmpfs of exactly sizeBytes at path, creating path if
// needed.
//
// This exists because the new rootfs must NOT inherit the size cap of
// whatever filesystem its path happens to sit in. The default work dir is
// under /run, which on a systemd host is a tmpfs sized to a fraction of RAM
// (10-20% is typical: 83 MiB on a 415 MiB Raspberry Pi). Extracting a rootfs
// into it fails with ENOSPC long before RAM is actually exhausted, and the
// failure surfaces as a confusing mid-extract write error rather than
// "your rootfs does not fit".
//
// Mounting our own tmpfs makes the budget explicit and independent of the
// host's /run sizing.
func MountTmpfs(path string, sizeBytes uint64) error {
	if err := os.MkdirAll(path, 0o755); err != nil {
		return fmt.Errorf("create %s: %w", path, err)
	}
	opts := fmt.Sprintf("size=%d,mode=0755", sizeBytes)
	if err := unix.Mount("tmpfs", path, "tmpfs", unix.MS_NOSUID|unix.MS_NODEV, opts); err != nil {
		return fmt.Errorf("mount tmpfs (%s) at %s: %w", opts, path, err)
	}
	return nil
}

// UnmountTmpfs removes a tmpfs previously mounted by MountTmpfs. Used on the
// abort paths so a failed pivot does not leave a RAM-backed filesystem (and
// its contents) pinned on a host that is staying on its old OS.
func UnmountTmpfs(path string) error {
	return unix.Unmount(path, unix.MNT_DETACH)
}

// FreeBytes returns the free space available at path.
func FreeBytes(path string) (uint64, error) {
	var st unix.Statfs_t
	if err := unix.Statfs(path, &st); err != nil {
		return 0, err
	}
	return uint64(st.Bavail) * uint64(st.Bsize), nil
}

// UsageBytes returns the bytes consumed by the tree rooted at path,
// counting allocated blocks rather than apparent size so it matches what
// the filesystem actually charges.
func UsageBytes(path string) (uint64, error) {
	var total uint64
	err := filepath.WalkDir(path, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		var st unix.Stat_t
		if err := unix.Lstat(p, &st); err != nil {
			return nil // raced with a write; not worth failing the pivot over
		}
		total += uint64(st.Blocks) * 512
		return nil
	})
	return total, err
}
