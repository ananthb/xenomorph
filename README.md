# xenomorph

`xenomorph` `pivot_root`s a running Linux userland into a new in-memory rootfs.
It keeps the old root mountpoint around for inspection and modification.
The new rootfs can be an OCI image or a tarball.

## Installation

### From Release

Download the latest release tarball for your architecture:

```bash
curl -LO https://github.com/ananth/xenomorph/releases/latest/download/xenomorph-VERSION-x86_64-linux.tar.gz
tar xzf xenomorph-*.tar.gz
sudo mv xenomorph-*/bin/xenomorph /usr/local/bin/
```

### From Source (with Nix)

```bash
nix build
# or run directly
nix run . -- --help
```

### From Source (with Zig)

Requires Zig 0.15.x:

```bash
zig build -Doptimize=ReleaseSafe
sudo cp zig-out/bin/xenomorph /usr/local/bin/
```

## Usage

```bash
# Pivot to a local tarball
sudo xenomorph pivot ./rootfs.tar --exec /bin/bash

# Pivot to a registry image
sudo xenomorph pivot alpine:latest

# Pivot with custom old root location
sudo xenomorph pivot ubuntu:22.04 --keep-old-root /old

# Dry run to see what would happen
sudo xenomorph pivot alpine:latest --dry-run
```

## Requirements

- Linux kernel with pivot_root support
- CAP_SYS_ADMIN capability (typically requires root)
- For registry images: network access to container registry

## License

GPL3 - see [LICENSE](LICENSE) for details.
