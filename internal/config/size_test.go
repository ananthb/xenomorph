package config

import "testing"

func TestParseSize(t *testing.T) {
	const total = 4 << 30 // 4 GiB

	cases := []struct {
		in   string
		want uint64
		bad  bool
	}{
		{in: "512", want: 512},
		{in: "512K", want: 512 << 10},
		{in: "512M", want: 512 << 20},
		{in: "2G", want: 2 << 30},
		{in: "1T", want: 1 << 40},
		// The three spellings of the same size must agree; operators type
		// all three and a silent 1000-vs-1024 difference is a bad surprise
		// when it is the margin between fitting in RAM and an OOM.
		{in: "512MB", want: 512 << 20},
		{in: "512MiB", want: 512 << 20},
		{in: "50%", want: 2 << 30},
		{in: "100%", want: total},
		{in: " 256M ", want: 256 << 20},
		{in: "", bad: true},
		{in: "0%", bad: true},
		{in: "101%", bad: true},
		{in: "-5%", bad: true},
		{in: "banana", bad: true},
		{in: "12X", bad: true},
	}

	for _, c := range cases {
		got, err := ParseSize(c.in, total)
		if c.bad {
			if err == nil {
				t.Errorf("ParseSize(%q) = %d, want error", c.in, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("ParseSize(%q) unexpected error: %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("ParseSize(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}
