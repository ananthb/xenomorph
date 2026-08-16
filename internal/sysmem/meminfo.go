// Package sysmem reads /proc/meminfo and applies the same RAM-headroom
// safety check that the Zig version did before pivoting into a tmpfs
// rootfs (src/util/memory.zig).
package sysmem

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

// MemInfo is the subset of /proc/meminfo the pivot path looks at.
// All fields are in bytes.
type MemInfo struct {
	Total     uint64
	Free      uint64
	Available uint64
}

// Read parses /proc/meminfo and returns a MemInfo. Surfaces ENOENT
// when running off-Linux so callers can degrade gracefully.
func Read() (*MemInfo, error) {
	return readFrom("/proc/meminfo")
}

func readFrom(path string) (*MemInfo, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer f.Close()

	out := &MemInfo{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		colon := strings.IndexByte(line, ':')
		if colon < 0 {
			continue
		}
		key := line[:colon]
		rest := strings.TrimSpace(line[colon+1:])
		// Values are like "1234 kB" — strip the suffix.
		fields := strings.Fields(rest)
		if len(fields) == 0 {
			continue
		}
		n, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil {
			continue
		}
		// /proc/meminfo emits kB throughout (1 kB == 1024 bytes here,
		// despite the unit label).
		bytes := n * 1024
		switch key {
		case "MemTotal":
			out.Total = bytes
		case "MemFree":
			out.Free = bytes
		case "MemAvailable":
			out.Available = bytes
		}
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("scan %s: %w", path, err)
	}
	if out.Total == 0 {
		return nil, fmt.Errorf("invalid /proc/meminfo: no MemTotal")
	}
	if out.Available == 0 {
		// MemAvailable is missing on very old kernels; fall back to Free.
		out.Available = out.Free
	}
	return out, nil
}

// ReserveBytes is the RAM deliberately left unused by the new rootfs: 10% of
// total. The same constant the headroom check enforces, expressed once so the
// tmpfs we size and the check we run afterwards cannot disagree.
func (m *MemInfo) ReserveBytes() uint64 { return m.Total / 10 }

// RecommendRootfsBytes is the tmpfs size to give the new rootfs when the
// operator did not choose one: everything currently available, minus the
// reserve.
//
// Deliberately based on MemAvailable, not MemTotal. When the pivot runs the
// old OS is still holding its memory, so sizing off total would hand out RAM
// that is not actually free — turning an honest ENOSPC into an OOM kill
// partway through the extract. That is the worse failure: the OOM killer
// picks its own victim, and on a small host that is as likely to be sshd as
// it is to be xmorph.
func (m *MemInfo) RecommendRootfsBytes() uint64 {
	reserve := m.ReserveBytes()
	if m.Available <= reserve {
		return 0
	}
	return m.Available - reserve
}

// HeadroomCheck is the same rule as src/cmd/pivot.zig:412-452 and
// src/util/memory.zig:25-52: returns nil if at least 10% of total RAM
// would remain free after a rootfs of rootfsBytes is placed in tmpfs.
//
// warn is set when usage would consume more than 75% of available RAM
// without crossing the error threshold — the caller logs it as a warning.
func (m *MemInfo) HeadroomCheck(rootfsBytes uint64) (warn bool, err error) {
	var headroom uint64
	if m.Available > rootfsBytes {
		headroom = m.Available - rootfsBytes
	}
	minHeadroom := m.Total / 10
	if headroom < minHeadroom {
		return false, fmt.Errorf("insufficient RAM: rootfs %d MiB, available %d MiB, total %d MiB",
			rootfsBytes/(1024*1024), m.Available/(1024*1024), m.Total/(1024*1024))
	}
	warnHeadroom := m.Total / 4
	return headroom < warnHeadroom, nil
}
