package passphrase

import (
	"math"
	"regexp"
	"strings"
	"testing"
)

// The wordlist is a data file, and data files rot silently. These invariants
// are the ones the format actually depends on: a hyphen or an uppercase
// letter inside a word makes a hyphenated phrase ambiguous to read back, and
// a duplicate quietly costs entropy the docs claim we have.
func TestWordlistInvariants(t *testing.T) {
	if len(words) < 1000 {
		t.Fatalf("wordlist has %d words; too small to be the EFF list", len(words))
	}
	valid := regexp.MustCompile(`^[a-z]{3,6}$`)
	seen := make(map[string]bool, len(words))
	for _, w := range words {
		if !valid.MatchString(w) {
			t.Errorf("word %q is not 3-6 lowercase letters", w)
		}
		if seen[w] {
			t.Errorf("word %q appears twice", w)
		}
		seen[w] = true
	}
}

func TestNewShape(t *testing.T) {
	got, err := New()
	if err != nil {
		t.Fatalf("New() error: %v", err)
	}
	parts := strings.Split(got, "-")
	if len(parts) != DefaultWords {
		t.Fatalf("New() = %q, want %d hyphen-separated words", got, DefaultWords)
	}
	for _, p := range parts {
		if !inWordlist(p) {
			t.Errorf("New() = %q contains %q, which is not in the wordlist", got, p)
		}
	}
}

// A generator that returns the same thing every time still passes a shape
// test. This is the one that would catch it.
func TestGenerateVaries(t *testing.T) {
	const draws = 200
	seen := make(map[string]bool, draws)
	for range draws {
		got, err := New()
		if err != nil {
			t.Fatalf("New() error: %v", err)
		}
		seen[got] = true
	}
	// With ~31 bits, 200 draws colliding even once is a 1-in-10-million
	// event. Anything less than all-distinct means the source is broken.
	if len(seen) != draws {
		t.Errorf("%d draws produced only %d distinct passphrases", draws, len(seen))
	}
}

func TestGenerateWordCount(t *testing.T) {
	for _, n := range []int{1, 2, 3, 6} {
		got, err := Generate(n)
		if err != nil {
			t.Fatalf("Generate(%d) error: %v", n, err)
		}
		if c := strings.Count(got, "-") + 1; c != n {
			t.Errorf("Generate(%d) = %q, has %d words", n, got, c)
		}
	}
}

func TestGenerateRejectsNonPositive(t *testing.T) {
	for _, n := range []int{0, -1} {
		if _, err := Generate(n); err == nil {
			t.Errorf("Generate(%d) = nil error, want one", n)
		}
	}
}

// The package doc quotes a number at people deciding whether this is strong
// enough for their situation. If the wordlist shrinks, the number has to move
// with it.
func TestBitsOfEntropy(t *testing.T) {
	if got := BitsOfEntropy(0); got != 0 {
		t.Errorf("BitsOfEntropy(0) = %v, want 0", got)
	}
	got := BitsOfEntropy(DefaultWords)
	if got < 30 || got > 32 {
		t.Errorf("BitsOfEntropy(%d) = %v; the ~31-bit claim in the docs no longer holds",
			DefaultWords, got)
	}
	if want := 2 * BitsOfEntropy(1); math.Abs(BitsOfEntropy(2)-want) > 1e-9 {
		t.Errorf("BitsOfEntropy(2) = %v, want %v", BitsOfEntropy(2), want)
	}
}

func TestWordCount(t *testing.T) {
	if WordCount() != len(words) {
		t.Errorf("WordCount() = %d, want %d", WordCount(), len(words))
	}
}

func inWordlist(s string) bool {
	for _, w := range words {
		if w == s {
			return true
		}
	}
	return false
}
