# Rescue Shell

xmorph's original use case: pivot the running system into a clean rootfs
in RAM, with the old root mounted at `/mnt/oldroot`, so you can fix what's
broken on disk without rebooting from external media.

## When to use this

- A botched upgrade or config change left init / libc / your boot path
  unbootable, but the kernel still runs
- You need to unmount the root filesystem to `fsck`, resize, or restore it
- You need to recover data from a damaged disk with offline tools the
  broken OS doesn't have
- You want to investigate before deciding whether to reprovision

## When not to use this

- The kernel won't boot at all — xmorph needs a running Linux kernel to
  pivot from. Use a rescue USB, PXE, or out-of-band media.
- You're going to reprovision anyway — skip the rescue intermediate, see
  [reprovision/](reprovision/).
- The fix doesn't need a pivoted environment — just SSH into the running
  OS.

## Quick start: rescue with Tailscale SSH

```sh
sudo xmorph pivot \
  --image docker.io/library/alpine:latest \
  --tailscale.authkey tskey-auth-xxxxx \
  --force
```

What this does:

1. Pulls Alpine + the Tailscale image into a tmpfs in RAM
2. On a systemd host, relocates itself into a transient scope so your SSH
   session (or a `run0`/`systemd-run` wrapper) can't take it down when it
   ends — see [Surviving your SSH session](#surviving-your-ssh-session)
3. Coordinates with systemd / OpenRC / SysVinit to stop services
4. `pivot_root`s into the new rootfs
5. Brings up Tailscale in the new rootfs; the node appears as
   `<hostname>-xmorph` on your tailnet
6. Mounts the old root at `/mnt/oldroot`

Your SSH session drops when the pivot tears down the old OS's networking —
that's expected. You reconnect to the rescue node over Tailscale.

From your laptop:

```sh
ssh root@<hostname>-xmorph
```

If the host had Tailscale running before xmorph started, the rescue
node inherits the host's tailnet identity (same machine key, same ACLs,
same MagicDNS name) thanks to state migration — the `-xmorph` suffix
just makes it visually obvious in the admin UI which mode you're in.

Use an [ephemeral auth key](https://tailscale.com/kb/1085/auth-keys)
so the rescue node auto-deletes from your tailnet when xmorph exits.

## The `/mnt/oldroot` workflow

Once you're in the rescue shell, the disk that held your previous root is
mounted read-only at `/mnt/oldroot`. The whole point is that you can
poke at it without the OS that lived there being in the way.

Common patterns:

```sh
# Inspect without changing anything
ls /mnt/oldroot/etc/
cat /mnt/oldroot/var/log/messages | tail -200

# Need to write? Remount rw.
mount -o remount,rw /mnt/oldroot

# Chroot in to use the old root's tools (only works if /bin/sh + libc are intact)
for d in dev dev/pts proc sys run; do mount --rbind /$d /mnt/oldroot/$d; done
chroot /mnt/oldroot /bin/bash

# Restore from a backup tarball you brought via scp
scp backup.tar.gz root@<hostname>-xmorph:/tmp/
tar -xpf /tmp/backup.tar.gz -C /mnt/oldroot/

# Fsck the underlying block device — but unmount oldroot first
umount /mnt/oldroot
fsck -y /dev/sda2
mount /dev/sda2 /mnt/oldroot
```

When done, `reboot`. The tmpfs rootfs is lost on reboot; the system comes
back up on the (now-fixed) disk.

## Custom toolset

The default Alpine image is minimal. For LVM, BTRFS, encrypted disks,
network forensics tools, etc., bake a custom rescue image:

### `entrypoint.sh`

```sh
#!/bin/sh
set -eu
apk add --no-cache \
  lvm2 cryptsetup mdadm \
  btrfs-progs xfsprogs e2fsprogs-extra dosfstools ntfs-3g \
  gdisk parted util-linux \
  rsync curl wget rclone \
  vim less htop strace lsof tcpdump \
  openssh-client
exec /bin/sh
```

### Overlay layout

```
overlay/
└── entrypoint.sh       # chmod +x
```

### Run

```sh
sudo xmorph pivot \
  --image docker.io/library/alpine:latest \
  --rootfs ./overlay/ \
  --entrypoint /entrypoint.sh \
  --tailscale.authkey tskey-auth-xxxxx \
  --force
```

The image is cached at `/var/cache/xmorph` (override with
`--cache-dir`). Subsequent pivots with the same base image skip the
download and apk install, so the second pivot onward is instant.

For a fleet: pre-warm the cache on boot with `xmorph build` (see the
[systemd integration](#systemd-integration) section).

## Headscale

If you run [Headscale](https://github.com/juanfont/headscale) instead of
Tailscale's hosted control plane, point `--tailscale.server` at it:

```sh
sudo xmorph pivot --image alpine \
  --tailscale.authkey <key-from-headscale> \
  --tailscale.server https://headscale.example.com \
  --force
```

This appends `--login-server=https://headscale.example.com` to the
`tailscale up` invocation in the new rootfs.

## Rescue without Tailscale

If you have a routable IP (static, or DHCP with known address) or you're
on a serial console:

```sh
# Plain SSH on port 22 with your key
sudo xmorph pivot --image alpine \
  --ssh.port 22 \
  --ssh.authorized-keys "$(cat ~/.ssh/id_ed25519.pub)" \
  --force

# Already on a serial console — just stay attached and watch it run
sudo xmorph pivot --image alpine --force
```

The `--ssh.enable` path stands up a small pure-Go OpenSSH server inside
the pivoted rootfs on the given port (default 22) with an ephemeral
ed25519 host key. Auth is public-key (from `--ssh.authorized-keys`,
standard `authorized_keys` format, one per line) and/or password
(`--ssh.password`). Sessions run `/bin/sh` as root — the rescue rootfs
has no user database.

Give it neither and xmorph generates a root password: three random words
from the EFF short wordlist, joined by hyphens, printed as a banner both
before the pivot and again after it.

```
  ============================================================
  SSH is enabled and no credentials were given, so xmorph
  generated a root password for it:

      swan-pesky-tofu

  Log in with:  ssh -p 22 root@<this machine>
  Write it down. Nothing keeps a copy you can read later.
  ============================================================
```

It is printed twice on purpose. The first copy goes to the terminal you
ran `xmorph pivot` from, which is usually the SSH session the pivot is
about to kill; the second goes to the console after the pivot, where a
serial line will still have it.

| | |
|---|---|
| Strength | ~31 bits — three words from a 1295-word list |
| Good for | the minutes-to-hours a rescue lasts, against online guessing |
| Not good for | a box left facing the open internet; use `--ssh.authorized-keys` |
| Where it ends up | the console, and `xmorph.log` under `--log-persist-path` |

A password you pass yourself is never printed and never logged — it may
be one you use elsewhere, so xmorph treats it as yours. Only the
generated one, which is worthless anywhere else and useless if you
cannot read it, goes to the console.

It assumes the network already works: your machine's interface stays
up across the pivot, but if the broken OS had odd routing or firewall
rules, those die with it. The firewall is flushed by default during
pivot; pass `--keep-firewall` to keep it.

## Surviving your SSH session

Rescuing from an existing SSH session works without any special flag. The
risk it guards against is your login session — or a `run0`/`systemd-run`
wrapper — being a systemd unit that gets torn down (with
`KillMode=control-group`) the moment it ends, which would SIGKILL xmorph
mid-pivot.

On a **systemd** host, xmorph handles this automatically: before it starts
building the rootfs it asks systemd to adopt the running process into a
transient scope (`xmorph-<pid>.scope`) — the same move `systemd-run
--scope` makes, but for the already-running process. That scope is
systemd-owned and independent of your session, so the pivot survives the
session ending. No fork, no re-exec; systemd just reassigns the cgroup.

xmorph also notices when it's running over SSH:

- If it detached into a scope, it logs a reminder that the session will
  drop during the pivot and you should reconnect via Tailscale/SSH in the
  new rootfs.
- If it could **not** detach (a non-systemd host, or the relocation
  failed), it warns that a disconnect may kill the pivot and pauses for a
  short grace window — `Ctrl-C` to abort. On those hosts, run it under a
  detachment mechanism of your own (`systemd-run`, `setsid`, `nohup`, `tmux`).

Make sure you have a way back in before you pivot: set `--tailscale.authkey`
or `--ssh.port`, or you'll lock yourself out. `--log-dir` (default
`/var/log`) writes `xmorph.log` on the old root and flushes it into the new
rootfs, so there's a breadcrumb trail either way.

### Running as a managed unit

If you drive the pivot from a systemd unit yourself — a `rescue.target`
unit, or `systemd-run --unit xmorph-pivot -- xmorph pivot …` — pass
`--systemd-mode` instead. It skips the self-relocation and the init
coordination (systemd already stopped services on the way into the target)
and implies `--force`. See [systemd integration](systemd.md).

## Auto-reset on hang

If the entrypoint hangs, the pivoted rootfs may be unreachable. `--watchdog-timeout` arms
`/dev/watchdog` before the entrypoint runs and pets it from a goroutine;
if anything stops that goroutine the kernel resets and the box comes
back on the original OS.

```sh
sudo xmorph pivot --image alpine --rootfs ./overlay/ \
  --entrypoint /install.sh \
  --watchdog-timeout 5m --force \
  --tailscale.authkey tskey-auth-xxxxx
```

xmorph checks pre-pivot that `/dev/watchdog` is available; if it's
missing it runs `modprobe softdog` and retries. If softdog can't load
either, the pivot aborts before touching the running OS — a locked-out
box is worse than a clear "watchdog can't be armed on this host, drop
`--watchdog-timeout` or fix the kernel." Sub-second timeouts are
rejected.

## Persistent logs

xmorph writes its own log and the entrypoint's stdout+stderr to
`/var/log/xmorph/` on the old rootfs by default. Since the pivoted
rootfs is tmpfs and gone on the next reboot, this is where you look
after a failed install. Change the location with `--log-persist-path`
and `--log-persist-device`; empty `--log-persist-path` disables. The
pivot aborts pre-pivot if the resolved directory isn't writable.

```sh
sudo xmorph pivot --image alpine --rootfs ./overlay/ \
  --entrypoint /install.sh \
  --log-persist-device /srv --log-persist-path xmorph
# Post-reboot, on the recovered OS:
tail /srv/xmorph/xmorph.log /srv/xmorph/entrypoint.log
```

## Recovery and exit

- **Back to the old OS**: `reboot`. The tmpfs is lost; the system comes
  up on disk.
- **Reprovision from the rescue shell**: just run `xmorph pivot` again
  from inside the rescue with an installer image — see
  [reprovision/](reprovision/).
- **Persist changes**: anything you write under `/` lives in RAM and dies
  on reboot. To persist, write to `/mnt/oldroot/` or `chroot` into it.

## systemd integration

For an always-available rescue path that you can trigger remotely without
rebuilding the image every time, install xmorph as a `rescue.target`
unit. See [systemd integration](systemd.md) for the unit file and NixOS
module. Once installed:

```sh
sudo systemctl isolate rescue.target
```

pivots into the configured rescue rootfs. A `xmorph-cache-warm.service`
runs on `multi-user.target` to pre-pull the image during normal boot, so
the pivot itself is sub-second when you actually need it.

## See also

- [Main README](../README.md) — install
- [systemd integration](systemd.md) — rescue.target unit + NixOS module
- `xmorph --help` and `xmorph pivot --help` — full flag reference
- [Reprovisioning](reprovision/) — replace the OS instead of rescuing it
- [Tailscale auth keys](https://tailscale.com/kb/1085/auth-keys) — prefer
  ephemeral for rescue use
- [Headscale](https://github.com/juanfont/headscale) — self-hosted control
  plane
