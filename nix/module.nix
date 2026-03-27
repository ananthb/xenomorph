{ config, lib, pkgs, ... }:

let
  cfg = config.services.xenomorph;

  # Common layer args shared between pivot and build
  layerArgs =
    (map (img: "--image ${img}") cfg.images)
    ++ (map (r: "--rootfs ${r}") cfg.rootfs)
    ++ lib.optional (cfg.tailscale.enable && cfg.tailscale.image != null) "--tailscale-image ${cfg.tailscale.image}"
    ++ lib.optional (cfg.tailscale.enable && cfg.tailscale.authKeyFile != null)
      "--tailscale-authkey $(cat ${cfg.tailscale.authKeyFile})"
    ++ lib.optional (cfg.tailscale.enable && cfg.tailscale.args != null) "--tailscale-args '${cfg.tailscale.args}'"
    ++ lib.optional cfg.verbose "--verbose";

  # Build the xenomorph pivot command line
  # Build command for cache pre-warming (no output, just cache)
  xenomorphBuildArgs = lib.concatStringsSep " " (
    [ "build" ] ++ layerArgs
  );

  # Pivot command
  xenomorphArgs = lib.concatStringsSep " " (
    [ "pivot" "--systemd-mode" "--force" ]
    ++ layerArgs
    ++ lib.optional (cfg.entrypoint != null) "--entrypoint ${cfg.entrypoint}"
    ++ (map (c: "--command ${c}") cfg.command)
    ++ lib.optional (cfg.workDir != null) "--work-dir ${cfg.workDir}"
    ++ lib.optional (cfg.logDir != null) "--log-dir ${cfg.logDir}"
  );
in
{
  options.services.xenomorph = {
    enable = lib.mkEnableOption "xenomorph rescue pivot service";

    package = lib.mkOption {
      type = lib.types.package;
      description = "The xenomorph package to use.";
    };

    images = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "docker.io/library/alpine:latest" ];
      description = "OCI images to merge into the rootfs (in order).";
    };

    rootfs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Local rootfs paths/tarballs to merge (in order with images).";
    };

    entrypoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Entrypoint override. Null uses the image default.";
    };

    command = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Command/arguments passed to the entrypoint.";
    };

    verbose = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable verbose logging.";
    };

    workDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Working directory for rootfs extraction.";
    };

    logDir = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Log directory.";
    };

    warmupBuildCache = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Pull images and build rootfs on boot so pivot is instant.";
    };

    tailscale = {
      enable = lib.mkEnableOption "Tailscale integration";

      image = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Tailscale OCI image override (default: docker.io/tailscale/tailscale:latest).";
      };

      authKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the Tailscale auth key.
          The file is read at runtime to avoid storing keys in the nix store.
          Required for tailscale to actually start and authenticate.
        '';
      };

      args = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Arguments for 'tailscale up' (default: --ssh --hostname=<host>-xenomorph).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # The xenomorph service runs as a oneshot triggered by rescue.target.
    # systemd isolates to rescue.target first (stopping all services),
    # then xenomorph pivots to the new rootfs.
    systemd.services.xenomorph-pivot = {
      description = "Xenomorph rootfs pivot";
      documentation = [ "https://github.com/ananthb/xenomorph" ];

      # Run after rescue.target is reached (services are stopped)
      after = [ "rescue.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "rescue.target" ];

      # Must have network for pulling images
      requires = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecStart = "${cfg.package}/bin/xenomorph ${xenomorphArgs}";

        # systemd sets CACHE_DIRECTORY for us
        CacheDirectory = "xenomorph";

        TimeoutStartSec = "infinity";
        Restart = "no";

        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
    };

    # Pre-warm the build cache during normal boot.
    systemd.services.xenomorph-cache-warm = lib.mkIf cfg.warmupBuildCache {
      description = "Xenomorph cache pre-warm";
      documentation = [ "https://github.com/ananthb/xenomorph" ];

      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${cfg.package}/bin/xenomorph ${xenomorphBuildArgs}";
        CacheDirectory = "xenomorph";
        TimeoutStartSec = "infinity";
        Restart = "no";
      };
    };
  };
}
