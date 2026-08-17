package config

import (
	"fmt"
	"strconv"
	"strings"
)

// ParseSize turns a human size into bytes. Accepts a plain byte count, an
// IEC suffix (K/M/G/T, optionally with an "i" and/or a trailing "B" — 512M,
// 512MiB and 512MB are all 512*1024*1024), or a percentage of total, which
// is why totalBytes is required.
//
// Percentages exist because the useful default here is relative: "half of
// RAM" is portable across a 415 MiB Pi and a 64 GiB server in a way that
// "2G" is not.
func ParseSize(s string, totalBytes uint64) (uint64, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, fmt.Errorf("empty size")
	}

	if pct, ok := strings.CutSuffix(s, "%"); ok {
		v, err := strconv.ParseFloat(strings.TrimSpace(pct), 64)
		if err != nil {
			return 0, fmt.Errorf("parse percentage %q: %w", s, err)
		}
		if v <= 0 || v > 100 {
			return 0, fmt.Errorf("percentage %q out of range (0, 100]", s)
		}
		return uint64(float64(totalBytes) * v / 100), nil
	}

	// Strip an optional trailing "B"/"iB" so 512MB, 512MiB and 512M agree.
	u := strings.ToUpper(s)
	u = strings.TrimSuffix(u, "B")
	u = strings.TrimSuffix(u, "I")

	mult := uint64(1)
	if len(u) > 0 {
		switch u[len(u)-1] {
		case 'K':
			mult = 1 << 10
		case 'M':
			mult = 1 << 20
		case 'G':
			mult = 1 << 30
		case 'T':
			mult = 1 << 40
		}
		if mult > 1 {
			u = u[:len(u)-1]
		}
	}

	n, err := strconv.ParseUint(strings.TrimSpace(u), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("parse size %q: %w", s, err)
	}
	if n > (1<<64-1)/mult {
		return 0, fmt.Errorf("size %q overflows", s)
	}
	return n * mult, nil
}
