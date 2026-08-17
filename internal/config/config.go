// Package config defines the xmorph CLI configuration and parsing.
//
// The struct mirrors src/config.zig in the Zig version, minus the
// containerfile/context fields (Containerfile support was dropped in the Go
// rewrite — see the port plan).
package config

import "time"

// Subcommand identifies which top-level command the user invoked.
type Subcommand int

const (
	SubcommandPivot Subcommand = iota
	SubcommandBuild
)

func (s Subcommand) String() string {
	switch s {
	case SubcommandPivot:
		return "pivot"
	case SubcommandBuild:
		return "build"
	}
	return "unknown"
}

// LayerKind tags Layer values.
type LayerKind int

const (
	LayerImage LayerKind = iota
	LayerRootfs
)

// Layer is a single source for the rootfs: either an OCI image reference
// (pulled from a registry, a local docker-save tarball, or a local OCI
// layout dir) or a local rootfs (plain directory or .tar/.tar.gz tarball).
type Layer struct {
	Kind LayerKind
	// Ref is the image reference when Kind == LayerImage.
	Ref string
	// Path is the local path when Kind == LayerRootfs.
	Path string
}

// Default values mirrored from src/config.zig:22-105 with paths renamed to xmorph.
const (
	DefaultImage          = "docker.io/library/alpine:latest"
	DefaultEntrypoint     = "/bin/sh"
	DefaultKeepOldRoot    = "/mnt/oldroot"
	DefaultTimeout        = 30
	DefaultCacheDir       = "/var/cache/xmorph"
	DefaultLogPersistPath = "/var/log/xmorph"
	DefaultWorkDir        = "/run/xmorph/rootfs"
	DefaultLogDir         = "/var/log"
	DefaultTailscaleImg   = "docker.io/tailscale/tailscale:latest"
)

// Config holds the parsed CLI configuration. Field order and zero-values
// follow src/config.zig as closely as Go allows.
type Config struct {
	Subcommand Subcommand

	// Layers is the ordered list of layers to merge into the rootfs.
	// Later layers win on file conflicts. If empty after parsing, the
	// default {Image: alpine:latest} layer is inserted.
	Layers []Layer

	Entrypoint         string
	EntrypointExplicit bool
	Command            []string

	KeepOldRoot string

	Contain     bool
	Force       bool
	Timeout     uint32
	NoInitCoord bool
	SystemdMode bool
	Verbose     bool
	DryRun      bool
	SkipVerify  bool
	NoCache     bool

	CacheDir string
	WorkDir  string

	// LogDir is an additional on-disk log sink: xmorph mirrors its slog
	// output to {LogDir}/xmorph.log (alongside stderr/journald and syslog)
	// and flushes the in-memory buffer there just before pivot_root, so the
	// pre-pivot log survives into the new rootfs. Empty disables the file sink.
	LogDir string

	Output       string // build subcommand: OCI layout output dir; empty = cache only
	RootfsOutput string // build subcommand: optional rootfs tarball output

	KeepFirewall bool

	// WatchdogTimeout is the deadline after which the post-pivot supervisor
	// resets the box if it hasn't returned to a healthy state. Zero disables
	// it. Prefers /dev/watchdog (kernel), falls back to a userspace timer.
	WatchdogTimeout time.Duration

	// LogPersistDevice + LogPersistPath compose the pre-pivot absolute
	// path where xmorph writes durable logs. Post-pivot the same path
	// is visible under KeepOldRoot. Empty LogPersistPath disables.
	LogPersistDevice string
	LogPersistPath   string

	// SSH: tri-state Enable (nil = auto from other ssh.* flags), explicit
	// fields below.
	SSHEnable         *bool
	SSHPort           *uint16
	SSHPassword       string
	SSHAuthorizedKeys string

	// Tailscale: tri-state Enable (nil = auto from authkey set).
	TailscaleEnable  *bool
	TailscaleImage   string
	TailscaleAuthkey string
	TailscaleServer  string
	TailscaleArgs    string
}

// New returns a Config populated with the same defaults the Zig version
// applies via its struct field defaults (src/config.zig:22-105).
func New() Config {
	return Config{
		Subcommand:     SubcommandPivot,
		Entrypoint:     DefaultEntrypoint,
		KeepOldRoot:    DefaultKeepOldRoot,
		Timeout:        DefaultTimeout,
		CacheDir:       DefaultCacheDir,
		LogPersistPath: DefaultLogPersistPath,
		WorkDir:        DefaultWorkDir,
		LogDir:         DefaultLogDir,
		TailscaleImage: DefaultTailscaleImg,
	}
}

// SSHEnabled reports whether SSH should be brought up in the new rootfs.
// Mirrors src/config.zig:107-110.
func (c *Config) SSHEnabled() bool {
	if c.SSHEnable != nil {
		return *c.SSHEnable
	}
	return c.SSHPort != nil || c.SSHPassword != "" || c.SSHAuthorizedKeys != ""
}

// TailscaleEnabled reports whether Tailscale should be brought up.
// Mirrors src/config.zig:112-115.
func (c *Config) TailscaleEnabled() bool {
	if c.TailscaleEnable != nil {
		return *c.TailscaleEnable
	}
	return c.TailscaleAuthkey != ""
}

// HasInitServices reports whether anything in the post-pivot init path
// has work to do. Mirrors src/config.zig:117-119.
func (c *Config) HasInitServices() bool {
	return c.SSHEnabled() || c.TailscaleEnabled() || !c.KeepFirewall
}
