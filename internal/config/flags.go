package config

import (
	"os"

	"github.com/spf13/pflag"
)

// BindPivot wires every pivot-subcommand flag onto fs, with their backing
// fields on cfg. After parsing, the caller must invoke cfg.Normalize() to
// apply implied-flag rules and environment-variable overrides.
//
// Surface mirrors src/config.zig:202-319 (parsePivotArgs) minus the dropped
// containerfile flags (--containerfile / --dockerfile / --context).
func BindPivot(fs *pflag.FlagSet, cfg *Config) {
	bindCommon(fs, cfg)
	bindPivotOnly(fs, cfg)
	bindSSH(fs, cfg)
	bindTailscale(fs, cfg)
}

// BindBuild wires every build-subcommand flag onto fs.
// Mirrors src/config.zig:321-374 (parseBuildArgs).
func BindBuild(fs *pflag.FlagSet, cfg *Config) {
	cfg.Subcommand = SubcommandBuild

	bindCommon(fs, cfg)
	bindBuildOnly(fs, cfg)
	// Build also accepts --tailscale.* (parity with Zig's parseBuildArgs:348-357).
	bindTailscale(fs, cfg)
}

func bindCommon(fs *pflag.FlagSet, cfg *Config) {
	// Layer flags — shared backing slice; pflag preserves argv order.
	fs.Var(&layerVar{dst: &cfg.Layers, kind: LayerImage}, "image", "OCI image reference (repeatable; merged left to right with --rootfs)")
	fs.Var(&layerVar{dst: &cfg.Layers, kind: LayerRootfs}, "rootfs", "local rootfs directory or tarball (repeatable; merged left to right with --image)")

	fs.BoolVarP(&cfg.Verbose, "verbose", "v", false, "verbose output")
	fs.BoolVar(&cfg.NoCache, "no-cache", false, "skip build cache, pull fresh")
	fs.StringVar(&cfg.WorkDir, "work-dir", DefaultWorkDir, "working directory for rootfs extraction")
}

func bindPivotOnly(fs *pflag.FlagSet, cfg *Config) {
	// --entrypoint tracks whether the user set it explicitly so we can
	// fall back to the image's ImageConfig.Entrypoint when they didn't.
	// pflag exposes the "Changed" bit via fs.Changed("entrypoint") at
	// parse time; Normalize() reads that.
	fs.StringVar(&cfg.Entrypoint, "entrypoint", DefaultEntrypoint, "entrypoint for the new rootfs")

	// --command / --cmd: shared backing slice, always-appending.
	fs.Var(&appendStringVar{dst: &cfg.Command}, "command", "command/args passed to entrypoint (repeatable)")
	fs.Var(&appendStringVar{dst: &cfg.Command}, "cmd", "alias for --command")

	// --keep-old-root with optional value: bare form uses the default,
	// --keep-old-root=/foo overrides. --no-keep-old-root clears it.
	fs.StringVar(&cfg.KeepOldRoot, "keep-old-root", DefaultKeepOldRoot, "keep old root mounted at PATH after pivot (default /mnt/oldroot)")
	keepFlag := fs.Lookup("keep-old-root")
	if keepFlag != nil {
		keepFlag.NoOptDefVal = DefaultKeepOldRoot
	}
	fs.BoolVar(new(bool), "no-keep-old-root", false, "unmount old root after pivot")

	fs.BoolVarP(&cfg.Contain, "contain", "c", false, "run in mount+PID namespace instead of pivot_root (testing)")
	fs.BoolVarP(&cfg.Force, "force", "f", false, "skip confirmation prompts")
	fs.Uint32Var(&cfg.Timeout, "timeout", DefaultTimeout, "service shutdown timeout in seconds")
	fs.BoolVar(&cfg.NoInitCoord, "no-init-coord", false, "skip init system coordination")
	fs.BoolVarP(&cfg.DryRun, "dry-run", "n", false, "show what would be done without executing")
	fs.BoolVar(&cfg.SkipVerify, "skip-verify", false, "skip rootfs verification")
	fs.StringVar(&cfg.CacheDir, "cache-dir", DefaultCacheDir, "cache directory for OCI layers")
	fs.StringVar(&cfg.LogDir, "log-dir", DefaultLogDir, "additional log-file directory; xmorph.log is written here and flushed into the new rootfs before pivot (empty: disabled)")
	fs.BoolVar(&cfg.SystemdMode, "systemd-mode", false, "running as systemd unit (implies --no-init-coord and --force)")
	fs.BoolVar(&cfg.KeepFirewall, "keep-firewall", false, "keep existing firewall rules (default: flush before starting services)")
	fs.DurationVar(&cfg.WatchdogTimeout, "watchdog-timeout", 0, "reset the box if the pivoted entrypoint hangs longer than this (0: disabled; uses /dev/watchdog when available, otherwise a userspace timer)")
	fs.StringVar(&cfg.LogPersistDevice, "log-persist-device", "", "pre-pivot mount path holding the log directory (empty: old root)")
	fs.StringVar(&cfg.LogPersistPath, "log-persist-path", DefaultLogPersistPath, "path under --log-persist-device where xmorph writes durable logs (empty: disabled)")
}

func bindBuildOnly(fs *pflag.FlagSet, cfg *Config) {
	fs.StringVarP(&cfg.Output, "output", "o", "", "output OCI layout directory (empty: cache only)")
	fs.StringVar(&cfg.RootfsOutput, "rootfs-output", "", "also write a rootfs tarball at PATH")
	fs.StringVar(&cfg.CacheDir, "cache-dir", DefaultCacheDir, "cache directory for OCI layers")
}

func bindSSH(fs *pflag.FlagSet, cfg *Config) {
	fs.Var(&tristateBool{dst: &cfg.SSHEnable}, "ssh.enable", "enable SSH in the new rootfs (auto when other ssh.* set)")
	fs.Lookup("ssh.enable").NoOptDefVal = "true"
	fs.Var(&tristateUint16{dst: &cfg.SSHPort}, "ssh.port", "SSH listen port (default 22)")
	fs.StringVar(&cfg.SSHPassword, "ssh.password", "", "root password (default: random)")
	fs.StringVar(&cfg.SSHAuthorizedKeys, "ssh.authorized-keys", "", "authorized public keys (inline)")
}

func bindTailscale(fs *pflag.FlagSet, cfg *Config) {
	fs.Var(&tristateBool{dst: &cfg.TailscaleEnable}, "tailscale.enable", "enable Tailscale (auto when --tailscale.authkey set)")
	fs.Lookup("tailscale.enable").NoOptDefVal = "true"
	fs.StringVar(&cfg.TailscaleImage, "tailscale.image", DefaultTailscaleImg, "deprecated: ignored under tsnet (kept for backward compatibility)")
	fs.StringVar(&cfg.TailscaleAuthkey, "tailscale.authkey", "", "Tailscale auth key (starts Tailscale via tsnet)")
	fs.StringVar(&cfg.TailscaleServer, "tailscale.server", "", "Tailscale coordination server URL (for Headscale)")
	fs.StringVar(&cfg.TailscaleArgs, "tailscale.args", "", "extra arguments for tailscale up (default: --ssh --hostname=<host>-xmorph)")
}

// Normalize applies post-parse adjustments that the Zig version performs
// inline during argv iteration: implied flags, default ports, and
// environment-variable overrides.
//
// fs is the FlagSet that produced cfg (so we can inspect Changed()).
// envLookup is the env-var lookup function (os.LookupEnv in production,
// overridable for tests).
func (c *Config) Normalize(fs *pflag.FlagSet, positional []string, envLookup func(string) (string, bool)) {
	if envLookup == nil {
		envLookup = os.LookupEnv
	}

	// Env-var overrides apply only when the matching flag wasn't set
	// explicitly. Mirrors src/config.zig:188-200.
	if !fs.Changed("cache-dir") {
		if dir, ok := envLookup("CACHE_DIRECTORY"); ok && dir != "" {
			c.CacheDir = dir
		}
	}
	if !fs.Changed("work-dir") {
		if dir, ok := envLookup("RUNTIME_DIRECTORY"); ok && dir != "" {
			c.WorkDir = dir + "/rootfs"
		}
	}

	// --no-keep-old-root overrides --keep-old-root: the Zig version sets
	// keep_old_root = "" in that case (src/config.zig:235-237).
	if fs.Changed("no-keep-old-root") {
		c.KeepOldRoot = ""
	}

	c.EntrypointExplicit = fs.Changed("entrypoint")

	// Implied flags: see src/config.zig:260-266.
	if c.SystemdMode {
		c.NoInitCoord = true
		c.Force = true
	}

	// --ssh.{password,authorized-keys,enable} imply port 22 unless port
	// was set explicitly. Mirrors src/config.zig:273-283.
	if c.SSHPort == nil {
		needPort := false
		if c.SSHEnable != nil && *c.SSHEnable {
			needPort = true
		}
		if c.SSHPassword != "" {
			needPort = true
		}
		if c.SSHAuthorizedKeys != "" {
			needPort = true
		}
		if needPort {
			p := uint16(22)
			c.SSHPort = &p
		}
	}

	// Positional args (anything after `--`) get appended to the command
	// list. Mirrors src/config.zig:294-298.
	if len(positional) > 0 {
		c.Command = append(c.Command, positional...)
	}

	// Default layer: alpine:latest if user provided nothing.
	if len(c.Layers) == 0 {
		c.Layers = []Layer{{Kind: LayerImage, Ref: DefaultImage}}
	}

	// Deduplicate (last occurrence wins position, in declaration order).
	c.Layers = DeduplicateLayers(c.Layers)
}
