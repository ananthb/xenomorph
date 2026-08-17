package sysmem

import "testing"

// The Raspberry Pi 3A+ that motivated the tmpfs work: 415 MiB total, ~246 MiB
// available. The old behaviour extracted into /run, capped at 83 MiB, while
// the headroom check (which was never called) would have looked at the 246
// and happily approved. Both numbers matter, and they are not the same
// number — that is the whole bug.
func TestRecommendRootfsBytes_SmallHost(t *testing.T) {
	m := &MemInfo{
		Total:     415 << 20,
		Available: 246 << 20,
	}

	got := m.RecommendRootfsBytes()
	want := uint64(246<<20) - uint64(415<<20)/10 // available - 10% of total
	if got != want {
		t.Fatalf("RecommendRootfsBytes() = %d MiB, want %d MiB", got>>20, want>>20)
	}

	// It must beat the /run cap that was silently in force before, or the
	// fix buys nothing on exactly the host that needed it.
	const runCap = 83 << 20
	if got <= runCap {
		t.Errorf("recommended %d MiB is no better than the /run cap of %d MiB", got>>20, runCap>>20)
	}

	// And whatever it recommends must survive its own headroom check,
	// otherwise the default configuration refuses to run.
	if _, err := m.HeadroomCheck(got); err != nil {
		t.Errorf("recommended size fails HeadroomCheck: %v", err)
	}
}

func TestRecommendRootfsBytes_NoRoom(t *testing.T) {
	// Available at or below the reserve leaves nothing to hand out. Zero is
	// the signal for "refuse", not a size to mount.
	m := &MemInfo{Total: 1 << 30, Available: 64 << 20}
	if got := m.RecommendRootfsBytes(); got != 0 {
		t.Errorf("RecommendRootfsBytes() = %d, want 0 when available <= reserve", got)
	}
}

func TestReserveIsTenPercent(t *testing.T) {
	m := &MemInfo{Total: 1000, Available: 1000}
	if got := m.ReserveBytes(); got != 100 {
		t.Errorf("ReserveBytes() = %d, want 100", got)
	}
}
