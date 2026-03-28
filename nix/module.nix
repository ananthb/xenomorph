{ config, lib, pkgs, ... }:

let
  cfg = config.services.xenomorph;

  # Common layer args shared between pivot and build
  layerArgs =
    (map (img: "--image ${img}") cfg.images)
    ++ (map (r: "--rootfs ${r}") cfg.rootfs)
    ++ lib.optional cfg.tailscale.enable "--tailscale.enable"
    ++ lib.optional (cfg.tailscale.enable && cfg.tailscale.image != null) "--tailscale.image=${cfg.tailscale.image}"
    ++ lib.optional (cfg.tailscale.enable && cfg.tailscale.authKeyFile != null)
      "--tailscale.authkey=$(cat ${cfg.tailscale.authKeyFile})"
    ++ lib.optional (cfg.tailscale.enable && cfg.tailscale.server != null) "--tailscale.server=${cfg.tailscale.server}"
    ++ lib.optional (cfg.tailscale.enable && cfg.tailscale.args != null) "--tailscale.args='${cfg.tailscale.args}'"
    ++ lib.optional cfg.ssh.enable "--ssh.enable"
    ++ lib.optional (cfg.ssh.enable && cfg.ssh.port != null) "--ssh.port=${toString cfg.ssh.port}"
    ++ lib.optional (cfg.ssh.enable && cfg.ssh.password != null) "--ssh.password=${cfg.ssh.password}"
    ++ lib.optional (cfg.ssh.enable && cfg.ssh.authorizedKeys != null) "--ssh.authorized-keys='${cfg.ssh.authorizedKeys}'"
    ++ lib.optional cfg.verbose "--verbose";

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

    ssh = {
      enable = lib.mkEnableOption "Dropbear SSH in the new rootfs";

      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "SSH port (default: 22).";
      };

      password = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "SSH root password. Null generates a random one.";
      };

      authorizedKeys = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "SSH authorized public keys (inline).";
      };
    };

    tailscale = {
      enable = lib.mkEnableOption "Tailscale integration";

      image = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Tailscale OCI image override.";
      };

      authKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing the Tailscale auth key.
          The file is read at runtime to avoid storing keys in the nix store.
        '';
      };

      server = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Tailscale coordination server URL (for Headscale).";
      };

      args = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Arguments for 'tailscale up' (default: --ssh --hostname=<host>-xenomorph).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.xenomorph-pivot = {
      description = "Xenomorph rootfs pivot";
      documentation = [ "https://github.com/ananthb/xenomorph" ];

      after = [ "rescue.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "rescue.target" ];
      requires = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;

        ExecStart = "${cfg.package}/bin/xenomorph ${xenomorphArgs}";

        CacheDirectory = "xenomorph";
        RuntimeDirectory = "xenomorph";

        TimeoutStartSec = "infinity";
        Restart = "no";

        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };
    };

    systemd.services.xenomorph-cache-warm = lib.mkIf cfg.warmupBuildCache {
      description = "Xenomorph cache pre-warm";
      documentation = [ "https://github.com/ananthb/xenomorph" ];

      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cfg.package}/bin/xenomorph ${xenomorphBuildArgs}";
        CacheDirectory = "xenomorph";
        RuntimeDirectory = "xenomorph";
        TimeoutStartSec = "infinity";
        Restart = "no";
      };
    };
  };
}
