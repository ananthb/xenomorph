package config

import (
	"errors"
	"io"
	"testing"
)

// --serve runs nothing, so naming something to run is contradictory and must
// be rejected rather than silently resolved in either direction.
func TestValidateServeWithCommand(t *testing.T) {
	for _, tc := range []struct {
		name    string
		mutate  func(*Config)
		wantErr bool
	}{
		{"serve alone", func(c *Config) { c.Serve = true }, false},
		{"serve with command", func(c *Config) { c.Serve = true; c.Command = []string{"sleep", "1"} }, true},
		{"serve with entrypoint", func(c *Config) { c.Serve = true; c.EntrypointExplicit = true }, true},
		{"command without serve", func(c *Config) { c.Command = []string{"sleep", "1"} }, false},
		{"neither", func(*Config) {}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := New()
			tc.mutate(&cfg)
			err := cfg.Validate(io.Discard)
			if tc.wantErr && !errors.Is(err, ErrServeWithCommand) {
				t.Errorf("want ErrServeWithCommand, got %v", err)
			}
			if !tc.wantErr && errors.Is(err, ErrServeWithCommand) {
				t.Errorf("unexpected ErrServeWithCommand: %v", err)
			}
		})
	}
}
