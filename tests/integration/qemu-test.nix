# Nix expression to run the QEMU integration test
# Usage: nix-build tests/integration/qemu-test.nix && ./result/bin/run-qemu-test
{ pkgs ? import <nixpkgs> { } }:

let
  # Build xenomorph
  xenomorph = pkgs.stdenv.mkDerivation {
    pname = "xenomorph";
    version = "dev";
    src = ../..;

    nativeBuildInputs = [ pkgs.zig ];

    dontConfigure = true;
    dontInstall = true;

    buildPhase = ''
      runHook preBuild
      export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
      zig build -Doptimize=ReleaseSafe --prefix $out
      runHook postBuild
    '';
  };

  # Minimal kernel for testing
  kernel = pkgs.linuxPackages_latest.kernel;

  # Busybox for the test environment
  busybox = pkgs.busybox;

  # QEMU for running the VM
  qemu = pkgs.qemu_kvm;

  # Test runner script
  runQemuTest = pkgs.writeShellScriptBin "run-qemu-test" ''
    set -e

    echo "=== Xenomorph QEMU Integration Test ==="
    echo ""
    echo "Kernel: ${kernel}/bzImage"
    echo "Busybox: ${busybox}/bin/busybox"
    echo "Xenomorph: ${xenomorph}/bin/xenomorph"
    echo ""

    export KERNEL_PATH="${kernel}/bzImage"
    export BUSYBOX_PATH="${busybox}/bin/busybox"
    export XENOMORPH_PATH="${xenomorph}/bin/xenomorph"
    export QEMU_PATH="${qemu}/bin/qemu-system-x86_64"

    # Run the QEMU test
    exec ${xenomorph}/bin/qemu-test "$@"
  '';

  # Build the QEMU test executable
  qemuTest = pkgs.stdenv.mkDerivation {
    pname = "xenomorph-qemu-test";
    version = "dev";
    src = ../..;

    nativeBuildInputs = [ pkgs.zig ];

    dontConfigure = true;

    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
      zig build -Doptimize=ReleaseSafe
      zig build test-qemu -Doptimize=ReleaseSafe || true
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp zig-out/bin/xenomorph $out/bin/ || true
      cp zig-out/bin/qemu-test $out/bin/ || true
    '';
  };

in
pkgs.symlinkJoin {
  name = "xenomorph-qemu-test";
  paths = [ runQemuTest qemuTest ];

  meta = {
    description = "QEMU integration test for xenomorph";
    mainProgram = "run-qemu-test";
  };
}
