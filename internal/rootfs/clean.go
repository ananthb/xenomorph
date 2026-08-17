package rootfs

import (
	"fmt"
	"os"
	"path/filepath"
)

// CleanTarget empties dir without removing dir itself, creating it if it does
// not exist.
//
// The distinction matters: dir may be a mount point (the pivot path mounts a
// tmpfs at the work dir), and unlinking a mount point fails with EBUSY no
// matter how the caller feels about it. `os.RemoveAll(dir)` therefore breaks
// the moment the work dir stops being an ordinary directory, with an error —
// "device or resource busy" — that reads like a bug in the extractor rather
// than a lifecycle mistake.
//
// Removing the contents is also the more correct operation regardless: the
// caller wants an empty rootfs target, not a deleted one, and recreating the
// directory would drop whatever mode or mount the caller had arranged.
func CleanTarget(dir string) error {
	entries, err := os.ReadDir(dir)
	if os.IsNotExist(err) {
		return os.MkdirAll(dir, 0o755)
	}
	if err != nil {
		return fmt.Errorf("read %s: %w", dir, err)
	}
	for _, e := range entries {
		p := filepath.Join(dir, e.Name())
		if err := os.RemoveAll(p); err != nil {
			return fmt.Errorf("remove %s: %w", p, err)
		}
	}
	return nil
}
