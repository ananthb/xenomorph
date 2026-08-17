# End-to-end lifecycle tests for `xmorph pivot`.
#
# The existing nixos-pivot check runs Go unit tests inside a VM: it proves
# pivot_root and the mount ordering are correct. That is necessary and not
# sufficient. A pivot can execute flawlessly and still leave a machine with a
# running kernel and no userspace — reachable by ICMP, dead on every port,
# recoverable only by physically power-cycling it. That failure shipped, and
# nixos-pivot passed the whole time, because nothing asserted the machine was
# still there afterwards.
#
# So these tests assert on the machine's *liveness after the pivot*, not on the
# syscall. The observation channel matters: the NixOS test backdoor is a
# systemd service on the guest, so it dies with the old root and machine.succeed
# is unavailable post-pivot. The serial console survives, and so does a reboot,
# and between them every post-pivot outcome is observable.
{ pkgs, lib, xmorph-package }:

let
  # Minimal offline rootfs. No network in CI, so --rootfs with a local tarball
  # rather than --image. /bin/sh exists because rootfs verification requires
  # one of /sbin/init, /bin/sh, /bin/bash — not because we supervise it.
  test-rootfs = pkgs.runCommand "xmorph-lifecycle-rootfs" {
    nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];
  } ''
    mkdir -p rootfs/{bin,usr/local/bin,etc,dev,proc,sys,tmp,var/run}
    cp ${pkgs.pkgsStatic.busybox}/bin/busybox rootfs/bin/
    for cmd in sh ls cat echo sleep true false; do
      ln -sf busybox rootfs/bin/$cmd
    done
    tar -czf $out -C rootfs .
  '';

  # Shared guest. 2G matches nixos-pivot; the pivot builds a tmpfs rootfs.
  node = { ... }: {
    environment.systemPackages = [ xmorph-package pkgs.busybox ];
    virtualisation.memorySize = 2048;
  };

  # A pivot detached from the calling session, exactly as an operator would run
  # it over SSH. Output goes to the console, which is the only channel that
  # outlives the old root.
  pivotCmd = args: ''
    setsid nohup xmorph pivot --force --rootfs ${test-rootfs} \
      --no-init-coord ${args} > /dev/console 2>&1 < /dev/null &
  '';
in
{
  # The headline case: a rescue pivot must leave the machine UP.
  #
  # This is the test that would have caught the incident. Before the fix the
  # supervised entrypoint was a shell, it read EOF on a detached stdin, exited
  # 0, and took the SSH server down with it — while pivot_root itself, and
  # therefore nixos-pivot, remained perfectly green.
  idle-stays-up = pkgs.testers.nixosTest {
    name = "xmorph-lifecycle-idle-stays-up";
    nodes.machine = node;
    testScript = ''
      machine.wait_for_unit("multi-user.target")
      machine.succeed("${pkgs.busybox}/bin/busybox true")

      machine.execute(
          "${pivotCmd "--entrypoint /usr/local/bin/xmorph --cmd idle"}"
      )

      # xmorph idle logs this once it is holding the box up. Reaching it proves
      # the pivot completed AND that userspace survived it.
      machine.wait_for_console_text("serving; no entrypoint to supervise")

      # And it has to KEEP holding. A machine that pivots and then reboots
      # moments later is the loop this design exists to avoid, so watch for the
      # reboot banner and treat seeing it as the failure.
      try:
          machine.wait_for_console_text("no userspace left, rebooting", timeout=30)
          raise Exception("machine rebooted after pivoting; idle did not hold it up")
      except TimeoutError:
          pass
    '';
  };

  # An entrypoint that exits must reboot into the on-disk OS rather than
  # silently leaving a kernel with nothing on it. Recovery is directly
  # observable: the machine comes back and its systemd starts again, which
  # also restores the test backdoor.
  exit-reboots = pkgs.testers.nixosTest {
    name = "xmorph-lifecycle-exit-reboots";
    nodes.machine = node;
    testScript = ''
      machine.wait_for_unit("multi-user.target")

      # /bin/true exits 0 immediately. Status 0 is the important part: the
      # original bug treated a clean exit as success and simply returned,
      # which is what turned a stumble into a box needing physical access.
      machine.execute(
          "${pivotCmd "--entrypoint /bin/true"}"
      )

      machine.wait_for_console_text("no userspace left, rebooting")

      # The machine must actually come back on its own.
      machine.wait_for_unit("multi-user.target")
      machine.succeed("systemctl is-system-running --wait || true")
    '';
  };

  # A bare shell cannot survive being detached, so the pivot must be refused
  # before anything destructive happens — while the old root is still intact
  # and aborting is free.
  shell-refused-preflight = pkgs.testers.nixosTest {
    name = "xmorph-lifecycle-shell-refused-preflight";
    nodes.machine = node;
    testScript = ''
      machine.wait_for_unit("multi-user.target")

      # No TTY here, which is the whole point: this is how it arrives over SSH.
      out = machine.fail(
          "xmorph pivot --force --rootfs ${test-rootfs} --no-init-coord "
          "--entrypoint /bin/sh < /dev/null 2>&1"
      )
      assert "shell with no terminal attached" in out, out
      assert "--cmd idle" in out, "the error must name the way forward: " + out

      # Nothing may have happened. The machine is still itself, still on the
      # original root, still running the init it started with.
      machine.succeed("test -d /nix/store")
      machine.succeed("systemctl is-active multi-user.target")
      machine.succeed("test ! -e /mnt/oldroot/nix")
    '';
  };

  # resolv.conf handling is covered by unit tests in internal/postpivot, which
  # can exercise the absent / usable / stub-only / dangling-symlink cases far
  # more precisely than a VM can. Deliberately not duplicated here: a VM test
  # that only asserts "a file exists" would add minutes to CI and catch less.
}
