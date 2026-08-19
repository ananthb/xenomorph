# End-to-end lifecycle tests for `xmorph pivot`.
#
# The existing nixos-pivot check runs Go unit tests inside a VM: it proves
# pivot_root and the mount ordering are correct. That is necessary and not
# sufficient. A pivot can execute flawlessly and still leave a machine with a
# running kernel and no userspace — answering ICMP, dead on every port,
# recoverable only by physically power-cycling it. That failure shipped, and
# nixos-pivot passed the whole time, because nothing asserted the machine was
# still there afterwards.
#
# So these tests assert liveness *after* a real pivot_root. Two things about
# the environment decide how, and both are easy to get wrong:
#
#   * The NixOS backdoor that machine.succeed() speaks to is a systemd service
#     on the guest. It dies with the old root. Nothing on the pivoted machine
#     can be asked anything, so the assertions come from a second VM and from
#     the serial console.
#
#   * The guest is booted with `console=ttyS0 console=tty0`, and the last one
#     wins: /dev/console is the graphics console, which the driver never reads.
#     wait_for_console_text watches the serial line. Output has to go to
#     /dev/ttyS0 by name — writing to /dev/console is silence.
#
# The same properties are asserted far more cheaply by the Go tests in
# internal/postpivot/lifecycle_test.go, which is where a regression will
# actually be caught first. These exist because the Go tests substitute the
# reboot, and at some point someone has to check the real thing.
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

  # The machine that gets pivoted. 2G matches nixos-pivot; the pivot builds a
  # tmpfs rootfs and the headroom check refuses to start without room for it.
  #
  # The firewall is off because nftables rules live in the kernel and survive
  # pivot_root — leaving them up would block the post-pivot SSH port and make
  # a live machine look dead, which is the one distinction being drawn here.
  target = { ... }: {
    environment.systemPackages = [ xmorph-package ];
    virtualisation.memorySize = 2048;
    networking.firewall.enable = false;
  };

  # Launch a pivot the way an operator does: detached, no terminal, output on
  # the serial console because every other channel goes away with the old root.
  #
  # Deliberately one line. This gets interpolated into a Python string literal,
  # and a shell `\` continuation would put a raw newline inside that literal,
  # which Python rejects before the VM ever boots.
  pivotCmd = args:
    "setsid xmorph pivot --force --skip-verify --no-init-coord --verbose "
    + "--rootfs ${test-rootfs} ${args} > /dev/ttyS0 2>&1 < /dev/null &";
in
{
  # The headline case: a rescue pivot must leave the machine REACHABLE.
  #
  # This is the test that would have caught the incident. Before the fix the
  # supervised entrypoint was a shell, it read EOF on a detached stdin, exited
  # 0, and took the SSH server down with it — while pivot_root itself, and
  # therefore nixos-pivot, stayed perfectly green.
  #
  # "Reachable" has to mean a TCP service answering, not a ping. The bricked
  # machine replied to ping for hours; the kernel does that on its own, and it
  # is precisely what made the failure so slow to spot. So the assertion is a
  # connection to xmorph's own post-pivot SSH server, made from another VM,
  # after the machine that would normally answer questions has stopped
  # existing. Nothing in NixOS listens on 22 here, so the port is xmorph's
  # alone: open means userspace lived through the pivot.
  #
  # It also covers the credential half of "reachable". SSH is enabled with no
  # password and no keys, which is the shape that silently produced a dead
  # port, so the test reads the generated password off the console exactly as
  # an operator would and logs in with it.
  idle-stays-up = pkgs.testers.nixosTest {
    name = "xmorph-lifecycle-idle-stays-up";
    nodes = {
      inherit target;
      prober = { ... }: {
        environment.systemPackages = [ pkgs.netcat-openbsd pkgs.openssh pkgs.sshpass ];
      };
    };
    testScript = ''
      import re
      import time

      start_all()
      target.wait_for_unit("multi-user.target")
      prober.wait_for_unit("multi-user.target")

      # Nothing is listening yet — otherwise the assertion below proves nothing.
      prober.fail("nc -z -w 2 target 22")

      # Everything past this point runs against a machine whose backdoor is
      # about to die, so it all lives in a try/finally. When the script ends
      # the driver runs execute("sync") on every machine that is_up(), and
      # execute() calls connect(), which waits on the backdoor shell in a loop
      # with no way out. On the happy path that is merely wrong; on a failed
      # assertion it swallows the failure, because the run sits there until
      # the job timeout and gets scored as a hang instead of the one-line
      # error that actually explains it. crash() goes through QMP and needs
      # nothing from the guest, so it works in both cases — but only if it
      # runs in both cases.
      try:
          # No credentials at all. --ssh.enable used to be the trap: sshd
          # needs a password or a key, got neither, logged it to a console
          # nobody was reading, and never bound the port. xmorph now
          # generates one.
          target.execute(
              "${pivotCmd "--entrypoint /usr/local/bin/xmorph --cmd idle --ssh.enable"}"
          )

          # xmorph idle logs this once it is holding the box up.
          target.wait_for_console_text("serving; no entrypoint to supervise", timeout=180)

          # The real assertion, and the only one that distinguishes this from
          # the incident: someone else can still open a connection to it.
          prober.wait_until_succeeds("nc -z -w 2 target 22", timeout=120)

          # A generated password nobody can read is the same failure wearing a
          # different hat, so take it the way an operator does — off the
          # console.
          #
          # Not wait_for_console_text: that reads forward from a queue, and
          # the banner is printed *before* the "serving" line above, so by now
          # it is already in the past and waiting for it hangs until the
          # timeout. get_console_log() is the whole log since boot, which is
          # where it actually is. Poll it, so this does not depend on the
          # order xmorph happens to log things in.
          password = None
          for _ in range(60):
              match = re.search(
                  r"generated a root password for it:\s+([a-z]{3,6}-[a-z]{3,6}-[a-z]{3,6})",
                  target.get_console_log(),
              )
              if match:
                  password = match.group(1)
                  break
              time.sleep(1)
          assert password, (
              "no password on the console:\n" + target.get_console_log()[-4000:]
          )

          # And it has to actually let someone in. Force password auth so a
          # misconfigured sshd cannot pass this by accepting a key, or by
          # accepting nothing at all.
          ssh = (
              "sshpass -p '{}' ssh -o StrictHostKeyChecking=no "
              "-o UserKnownHostsFile=/dev/null -o PreferredAuthentications=password "
              "-o PubkeyAuthentication=no -o ConnectTimeout=10 -o NumberOfPasswordPrompts=1 "
              "root@target {}"
          )
          out = prober.wait_until_succeeds(
              ssh.format(password, "'echo logged-in'"), timeout=90
          )
          assert "logged-in" in out, out

          # An sshd that accepts every password would have passed the line
          # above.
          prober.fail(ssh.format("not-the-password", "true"), timeout=60)

          # And it has to KEEP holding. A machine that pivots and then reboots
          # moments later is the loop this design exists to avoid.
          prober.succeed("sleep 20")
          prober.succeed("nc -z -w 2 target 22")
      finally:
          # Best-effort: if the guest already died the point is moot, and an
          # exception here would mask the real one.
          try:
              target.crash()
          except Exception as e:  # noqa: BLE001
              print(f"target.crash() failed, continuing: {e}")
    '';
  };

  # An entrypoint that exits must reboot into the on-disk OS rather than leave
  # a kernel with nothing on it. Recovery is directly observable: the machine
  # boots again, which also restores the backdoor and lets the driver back in.
  #
  # allow_reboot is not optional. Without it the VM is started with
  # -no-reboot, and the guest rebooting takes QEMU down with it — the correct
  # behaviour would be scored as a crash.
  exit-reboots = pkgs.testers.nixosTest {
    name = "xmorph-lifecycle-exit-reboots";
    nodes.target = target;
    testScript = ''
      target.start(allow_reboot=True)
      target.wait_for_unit("multi-user.target")
      first_boot = target.succeed("cat /proc/sys/kernel/random/boot_id").strip()

      # /bin/true exits 0 immediately. Status 0 is the important part: the
      # original bug treated a clean exit as success and simply returned,
      # which is what turned a stumble into a box needing physical access.
      target.execute("${pivotCmd "--entrypoint /bin/true"}")

      # If the reboot never happens, the machine sits pivoted with a dead
      # backdoor, and the driver's end-of-script execute("sync") waits on it
      # forever — turning a legible assertion failure into a job timeout.
      # crash() goes through QMP and works without the guest. Only on the
      # failure path: when the reboot does happen the backdoor comes back and
      # the driver can shut down normally.
      try:
          target.wait_for_console_text("no userspace left, rebooting", timeout=180)

          # The backdoor went down with the old root; the reboot brings a new one.
          target.connected = False
          target.wait_for_unit("multi-user.target")

          second_boot = target.succeed("cat /proc/sys/kernel/random/boot_id").strip()
          assert first_boot != second_boot, (
              f"boot_id unchanged ({first_boot}); the machine never actually rebooted"
          )

          # Back on the real OS, not still in the pivoted rootfs.
          target.succeed("test -d /nix/store")
      except Exception:
          try:
              target.crash()
          except Exception as e:  # noqa: BLE001
              print(f"target.crash() failed, continuing: {e}")
          raise
    '';
  };

  # A bare shell cannot survive being detached, so the pivot must be refused
  # before anything destructive happens — while the old root is still intact
  # and aborting is free. No pivot happens here, so the backdoor lives and the
  # whole thing is ordinary machine.fail().
  shell-refused-preflight = pkgs.testers.nixosTest {
    name = "xmorph-lifecycle-shell-refused-preflight";
    nodes.target = target;
    testScript = ''
      target.wait_for_unit("multi-user.target")

      # No TTY here, which is the whole point: this is how it arrives over SSH.
      out = target.fail(
          "xmorph pivot --force --skip-verify --no-init-coord "
          "--rootfs ${test-rootfs} --entrypoint /bin/sh < /dev/null 2>&1"
      )
      assert "shell with no terminal attached" in out, out
      assert "--cmd idle" in out, "the error must name the way forward: " + out

      # Nothing may have happened. The machine is still itself, still on the
      # original root, still running the init it started with.
      target.succeed("test -d /nix/store")
      target.succeed("systemctl is-active multi-user.target")
      target.succeed("test ! -e /mnt/oldroot/nix")
    '';
  };

  # resolv.conf handling is covered by unit tests in internal/postpivot, which
  # can exercise the absent / usable / stub-only / dangling-symlink cases far
  # more precisely than a VM can. Deliberately not duplicated here: a VM test
  # that only asserts "a file exists" would add minutes to CI and catch less.
}
