// Package passphrase generates short, readable, hyphenated passphrases for
// credentials a human has to carry from one screen to another.
//
// The one caller today is `xmorph pivot --ssh.enable` with no credentials
// supplied. That password appears on a console and gets typed, by hand,
// against a machine that has just thrown away its userspace — so the words
// have to survive a phone camera, a serial terminal in an unfamiliar font,
// and someone reading them aloud. That rules out random characters, which is
// why this exists rather than a base64 of 16 random bytes.
//
// The wordlist is the EFF short wordlist #1 (CC BY 3.0 US, Electronic
// Frontier Foundation, 2016), chosen for exactly this property: every word is
// 3-5 letters, common, and distinguishable from the others by its first three
// characters. One entry, "yo-yo", is dropped here because a hyphen inside a
// word makes a hyphen-separated phrase ambiguous to read back.
package passphrase

import (
	"crypto/rand"
	_ "embed"
	"errors"
	"fmt"
	"math"
	"math/big"
	"strings"
)

//go:embed wordlist.txt
var wordlistRaw string

// words is the wordlist, split once at init. Lines starting with # are the
// attribution header, not words.
var words = parseWordlist(wordlistRaw)

func parseWordlist(raw string) []string {
	var out []string
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		out = append(out, line)
	}
	return out
}

// DefaultWords is how many words New uses.
//
// Three words out of 1295 is a shade under 31 bits. That is not a key, and it
// is not meant to be one: it protects a root shell for the minutes-to-hours a
// rescue pivot lasts, against an attacker who has to guess online. It is also
// strictly better than the alternative it replaces, which was a human picking
// a password at the command line — and far better than the alternative before
// that, which was no SSH at all because sshd silently refused to start.
//
// Raise this if the pivoted machine will face the open internet for long. It
// is a one-line change and each extra word adds ~10.3 bits.
const DefaultWords = 3

// New returns a DefaultWords-long hyphenated passphrase.
func New() (string, error) { return Generate(DefaultWords) }

// Generate returns an n-word hyphenated passphrase drawn uniformly from the
// wordlist with crypto/rand. Words may repeat: rejecting duplicates would
// remove entropy rather than add it, and at n=3 a repeat is a 1-in-432 curio,
// not a weakness.
func Generate(n int) (string, error) {
	if n <= 0 {
		return "", errors.New("passphrase: word count must be positive")
	}
	if len(words) == 0 {
		return "", errors.New("passphrase: wordlist is empty")
	}
	picked := make([]string, n)
	for i := range picked {
		// crypto/rand.Int is the uniform-without-modulo-bias primitive.
		// Reaching for math/big to pick one of 1295 things is overkill by
		// weight but exactly right by correctness, and this runs three times
		// in the life of a process.
		idx, err := rand.Int(rand.Reader, big.NewInt(int64(len(words))))
		if err != nil {
			return "", fmt.Errorf("passphrase: read randomness: %w", err)
		}
		picked[i] = words[idx.Int64()]
	}
	return strings.Join(picked, "-"), nil
}

// BitsOfEntropy reports the entropy of an n-word phrase from this wordlist,
// so callers can state the number rather than assert a vibe.
func BitsOfEntropy(n int) float64 {
	if n <= 0 || len(words) == 0 {
		return 0
	}
	return float64(n) * math.Log2(float64(len(words)))
}

// WordCount is the size of the wordlist. Exported for tests and for anyone
// checking the entropy claim above.
func WordCount() int { return len(words) }
