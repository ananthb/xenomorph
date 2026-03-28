# xenomorph

Replaces a running Linux root filesystem with a new in-memory rootfs
built from OCI (Docker) images, rootfs tarballs, and Containerfiles.
The old root is kept around for inspection and modification.

Works as a Linux rescue environment integrating with systemd's
`rescue.target`. Supports headless mode with Tailscale for SSH access
after the pivot.

Coordinates with systemd, OpenRC, and SysVinit to gracefully stop
services before pivoting.

## Principle of Operation

1. Pulls OCI images and/or extracts rootfs tarballs into a RAM-backed tmpfs
2. Merges multiple layers in order (later wins on file conflicts)
3. Coordinates with the init system to stop services
4. Calls `pivot_root(2)` to atomically swap the root filesystem
5. Execs the entrypoint in the new rootfs

The old root is accessible at `/mnt/oldroot` by default.

## Installation

### Static binaries

Download from [releases](https://github.com/ananthb/xenomorph/releases).
Binaries are fully static (musl libc) for x86_64, aarch64, and armv7:

```sh
curl -LO https://github.com/ananthb/xenomorph/releases/latest/download/xenomorph-x86_64-linux
chmod +x xenomorph-x86_64-linux
sudo mv xenomorph-x86_64-linux /usr/local/bin/xenomorph
```

Each release includes `SHA256SUMS` for verification.

### Nix

```sh
nix run github:ananthb/xenomorph -- --help
```

### From source

Requires Zig 0.15.x:

```sh
zig build -Doptimize=ReleaseSafe
sudo cp zig-out/bin/xenomorph /usr/local/bin/
```

## Usage

### Pivot to a new rootfs

```sh
# Default alpine image
sudo xenomorph pivot

# Specific image
sudo xenomorph pivot --image ubuntu:22.04

# Local rootfs tarball
sudo xenomorph pivot --rootfs ./my-rootfs.tar.gz

# Merge multiple layers (later wins on conflict)
sudo xenomorph pivot --image alpine:latest --rootfs ./extra-files/

# Custom entrypoint and command
sudo xenomorph pivot --image alpine:latest --entrypoint /bin/sh --command -c --command "echo hello"

# Dry run
sudo xenomorph pivot --dry-run
```

### Build an OCI image without pivoting

```sh
# Cache only (pre-warm for fast pivot later)
sudo xenomorph build --image alpine:latest

# Write OCI layout to disk
sudo xenomorph build --image alpine:latest -o my-image.oci

# Also write a rootfs tarball
sudo xenomorph build --image alpine:latest -o my-image.oci --rootfs-output rootfs.tar.gz
```

### Build from a Containerfile

```sh
sudo xenomorph pivot --containerfile ./Containerfile
sudo xenomorph build --containerfile ./Dockerfile --context ./app/
```

Supported instructions: `FROM`, `COPY`, `ADD`, `ENV`, `WORKDIR`,
`ENTRYPOINT`, `CMD`, `LABEL`, `ARG`, `EXPOSE`, `VOLUME`, `USER`.
`RUN` is not yet supported.

### Headless mode with Tailscale

For pivoting over SSH without losing your connection:

```sh
sudo xenomorph pivot --headless --tailscale-authkey tskey-auth-xxxxx
```

This forks into the background, pivots the root filesystem, and starts
Tailscale in the new rootfs. Reconnect via `ssh root@<hostname>-xenomorph`.

Use an [ephemeral auth key](https://tailscale.com/kb/1085/auth-keys) so
the node is automatically removed from your tailnet when xenomorph is done.

The `--headless` flag:
- Forks and detaches from the terminal (`setsid`)
- Logs to `/var/log/xenomorph.log` (configurable with `--log-dir`)
- Prints the Tailscale hostname and PID before forking
- Implies `--force` (no confirmation prompt)

### systemd rescue.target

xenomorph integrates with systemd as a rescue target service.
When the system enters rescue mode, xenomorph pivots to the configured rootfs.

A cache warmup service runs during normal boot to pre-pull images,
so the pivot is instant when rescue.target is reached.

#### NixOS module

```nix
{
  inputs.xenomorph.url = "github:ananthb/xenomorph";

  outputs = { self, nixpkgs, xenomorph, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        xenomorph.nixosModules.default
        {
          services.xenomorph = {
            enable = true;
            package = xenomorph.packages.x86_64-linux.default;

            # Images to merge into the rescue rootfs
            images = [ "docker.io/library/alpine:latest" ];

            # Tailscale for SSH access after pivot
            tailscale = {
              enable = true;
              authKeyFile = "/run/secrets/tailscale-key";
            };

            # Pre-warm cache on boot (default: true)
            warmupBuildCache = true;
          };
        }
      ];
    };
  };
}
```

This creates two systemd services:
- `xenomorph-cache-warm.service` — runs on `multi-user.target` to pre-pull images
- `xenomorph-pivot.service` — runs on `rescue.target` to pivot into the new rootfs

Trigger the pivot with:

```sh
sudo systemctl isolate rescue.target
```

#### Manual systemd setup

Service files are included in the release tarball under
[`init/systemd/`](init/systemd/):

- [`xenomorph-pivot.service`](init/systemd/xenomorph-pivot.service) — pivots on `rescue.target`
- [`xenomorph-cache-warm.service`](init/systemd/xenomorph-cache-warm.service) — pre-warms cache on boot

Install them:

```sh
sudo cp init/systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable xenomorph-pivot.service xenomorph-cache-warm.service
```

Edit the pivot service to configure your images and Tailscale auth key:

```sh
sudo systemctl edit xenomorph-pivot.service
```

```ini
[Service]
ExecStart=
ExecStart=/usr/local/bin/xenomorph pivot --systemd-mode --force --image alpine:latest --tailscale-authkey tskey-auth-xxxxx
```

The `--systemd-mode` flag skips init coordination and process termination
(systemd has already stopped services when entering rescue.target).
`CacheDirectory=xenomorph` sets `CACHE_DIRECTORY` so xenomorph uses
`/var/cache/xenomorph` automatically.

## Caching

xenomorph caches built rootfs images at the configured cache directory
(default `/var/cache/xenomorph`, overridable with `--cache-dir` or the
`CACHE_DIRECTORY` environment variable).

The cache key is derived from the normalized layer list. Repeated
`pivot` or `build` invocations with the same layers skip all image
pulls and layer merging.

Use `xenomorph build` with no output flags to pre-warm the cache.

## Requirements

- Linux kernel with `pivot_root` support
- Root privileges (`CAP_SYS_ADMIN`)
- Network access for pulling registry images

## License

Licensed under the terms of the [AGPL-3.0](LICENSE).
