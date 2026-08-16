package cli

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/ananthb/xmorph/internal/config"
	"github.com/ananthb/xmorph/internal/oci"
	"github.com/ananthb/xmorph/internal/rootfs"
	"github.com/spf13/cobra"
)

func newBuildCmd() *cobra.Command {
	cfg := config.New()

	cmd := &cobra.Command{
		Use:   "build",
		Short: "Build an OCI image from configured layers without pivoting",
		Long: `build assembles a rootfs from the configured layers and, with -o,
writes the result as an OCI layout directory. Without -o it just populates
the build cache so a later pivot is fast.`,
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg.Normalize(cmd.Flags(), args, nil)
			if err := cfg.Validate(cmd.ErrOrStderr()); err != nil {
				return err
			}
			return runBuild(cmd.Context(), &cfg)
		},
	}
	config.BindBuild(cmd.Flags(), &cfg)
	return cmd
}

// runBuild is the M2 entry point. It builds the rootfs into cfg.WorkDir,
// saves a cache entry at {cache_dir}/builds/{key}/, and (with -o) writes
// an OCI layout to the requested path.
func runBuild(ctx context.Context, cfg *config.Config) error {
	_ = ctx // M2 doesn't use the context; future remote-pull cancellation does

	key := rootfs.ComputeCacheKey(cfg.Layers)
	cachePath := filepath.Join(cfg.CacheDir, "builds", key)

	if !cfg.NoCache && cacheHit(cachePath) {
		slog.Info("cache hit", "key", key, "path", cachePath)
		if cfg.Output != "" {
			return copyLayoutDir(cachePath, cfg.Output)
		}
		return nil
	}

	// CleanTarget, not RemoveAll: the work dir may be a mount point (the
	// pivot path mounts a tmpfs there) and unlinking one fails with EBUSY.
	if err := rootfs.CleanTarget(cfg.WorkDir); err != nil {
		return fmt.Errorf("clean work dir: %w", err)
	}

	slog.Info("building rootfs", "layers", len(cfg.Layers), "target", cfg.WorkDir)
	result, err := rootfs.Build(cfg.Layers, cfg.WorkDir)
	if err != nil {
		return fmt.Errorf("build rootfs: %w", err)
	}
	slog.Info("rootfs built", "layers", result.LayerCount)

	img, err := composeImage(cfg.WorkDir, result.Config)
	if err != nil {
		return fmt.Errorf("compose OCI image: %w", err)
	}

	if err := os.MkdirAll(cachePath, 0o755); err != nil {
		return fmt.Errorf("create cache dir: %w", err)
	}
	digest, err := oci.WriteLayout(cachePath, img)
	if err != nil {
		return fmt.Errorf("write cache layout: %w", err)
	}
	slog.Info("cache saved", "key", key, "digest", digest.String())

	if cfg.Output != "" {
		if _, err := oci.WriteLayout(cfg.Output, img); err != nil {
			return fmt.Errorf("write OCI layout %s: %w", cfg.Output, err)
		}
		slog.Info("OCI layout written", "path", cfg.Output)
	}

	if cfg.RootfsOutput != "" {
		if err := writeRootfsTarball(cfg.WorkDir, cfg.RootfsOutput); err != nil {
			return fmt.Errorf("write rootfs tarball: %w", err)
		}
		slog.Info("rootfs tarball written", "path", cfg.RootfsOutput)
	}

	return nil
}

func cacheHit(path string) bool {
	_, err := os.Stat(filepath.Join(path, "index.json"))
	return err == nil
}
