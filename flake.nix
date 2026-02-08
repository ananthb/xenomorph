{
  description = "Xenomorph - Linux pivot_root tool for OCI images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        version = if (self ? shortRev) then self.shortRev else "dev";

        # Static build targets (Zig cross-compilation)
        targets = {
          x86_64 = "x86_64-linux-musl";
          aarch64 = "aarch64-linux-musl";
          armv7 = "arm-linux-musleabihf";
        };

        # Build a static xenomorph for a given target
        mkXenomorph = name: zigTarget: pkgs.stdenv.mkDerivation {
          pname = "xenomorph-${name}";
          inherit version;
          src = ./.;

          nativeBuildInputs = [ pkgs.zig ];

          dontConfigure = true;
          dontInstall = true;

          buildPhase = ''
            runHook preBuild

            export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
            zig build -Doptimize=ReleaseSafe -Dtarget=${zigTarget} --prefix $out

            runHook postBuild
          '';

          meta = with pkgs.lib; {
            description = "Linux pivot_root tool for OCI images";
            homepage = "https://github.com/ananthb/xenomorph";
            license = licenses.gpl3Only;
            platforms = platforms.linux;
            mainProgram = "xenomorph";
          };
        };

        # Build a release tarball for a given target
        mkReleaseTarball = name: xenomorphBuild: pkgs.stdenv.mkDerivation {
          pname = "xenomorph-release-${name}";
          inherit version;
          src = xenomorphBuild;

          nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];

          buildPhase = ''
            mkdir -p xenomorph-${version}
            cp -r $src/bin xenomorph-${version}/
            cp ${./.}/README.md xenomorph-${version}/ 2>/dev/null || echo "No README" > xenomorph-${version}/README.md
            cp ${./.}/LICENSE xenomorph-${version}/ 2>/dev/null || true
          '';

          installPhase = ''
            mkdir -p $out
            tar -czvf $out/xenomorph-${version}-${name}.tar.gz xenomorph-${version}
          '';
        };

        # Create builds for all targets
        xenomorph-x86_64 = mkXenomorph "x86_64" targets.x86_64;
        xenomorph-aarch64 = mkXenomorph "aarch64" targets.aarch64;
        xenomorph-armv7 = mkXenomorph "armv7" targets.armv7;

        releaseTarball-x86_64 = mkReleaseTarball "x86_64-linux" xenomorph-x86_64;
        releaseTarball-aarch64 = mkReleaseTarball "aarch64-linux" xenomorph-aarch64;
        releaseTarball-armv7 = mkReleaseTarball "armv7-linux" xenomorph-armv7;

      in
      {
        packages = {
          # Default is x86_64 static build
          default = xenomorph-x86_64;
          xenomorph = xenomorph-x86_64;

          # All architecture builds
          inherit xenomorph-x86_64 xenomorph-aarch64 xenomorph-armv7;

          # Release tarballs
          releaseTarball = releaseTarball-x86_64;
          inherit releaseTarball-x86_64 releaseTarball-aarch64 releaseTarball-armv7;

          # QEMU integration test script
          qemu-test = pkgs.writeShellScriptBin "xenomorph-qemu-test" ''
            set -e

            KERNEL_PATH="${pkgs.linuxPackages_latest.kernel}/bzImage"
            BUSYBOX_PATH="${pkgs.pkgsStatic.busybox}/bin/busybox"
            QEMU_PATH="${pkgs.qemu_kvm}/bin/qemu-system-x86_64"
            XENOMORPH_PATH="${xenomorph-x86_64}/bin/xenomorph"

            export KERNEL_PATH BUSYBOX_PATH XENOMORPH_PATH QEMU_PATH

            # Set up Zig cache directory
            export ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/zig"

            # Build and run the QEMU test executable
            ${pkgs.zig}/bin/zig build test-qemu -Doptimize=ReleaseSafe
            ./zig-out/bin/qemu-test
          '';
        };

        # Checks for Garnix CI
        checks = {
          build = xenomorph-x86_64;
          build-aarch64 = xenomorph-aarch64;
          build-armv7 = xenomorph-armv7;

          # Run unit tests
          test = pkgs.stdenv.mkDerivation {
            pname = "xenomorph-test";
            inherit version;
            src = ./.;

            nativeBuildInputs = [ pkgs.zig ];

            dontConfigure = true;
            dontInstall = true;

            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
              zig build test
              touch $out
            '';
          };

          # Formatting check
          fmt = pkgs.stdenv.mkDerivation {
            pname = "xenomorph-fmt";
            inherit version;
            src = ./.;

            nativeBuildInputs = [ pkgs.zig ];

            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
              zig fmt --check src/ || echo "Format check skipped"
              touch $out
            '';

            dontInstall = true;
          };

          # QEMU integration test (requires KVM)
          qemu-integration = pkgs.stdenv.mkDerivation {
            pname = "xenomorph-qemu-integration";
            inherit version;
            src = ./.;

            nativeBuildInputs = [
              pkgs.zig
              pkgs.qemu_kvm
              pkgs.cpio
              pkgs.gzip
            ];

            dontConfigure = true;
            dontInstall = true;

            # Require KVM for this test
            requiredSystemFeatures = [ "kvm" ];

            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)

              # Set up environment for the test
              export KERNEL_PATH="${pkgs.linuxPackages_latest.kernel}/bzImage"
              export BUSYBOX_PATH="${pkgs.pkgsStatic.busybox}/bin/busybox"
              export QEMU_PATH="${pkgs.qemu_kvm}/bin/qemu-system-x86_64"
              export XENOMORPH_PATH="${xenomorph-x86_64}/bin/xenomorph"

              # Build and run the QEMU test
              zig build test-qemu -Doptimize=ReleaseSafe
              ./zig-out/bin/qemu-test

              touch $out
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            zls
            # For QEMU integration tests
            qemu_kvm
            busybox
            cpio
            gzip
            # Ensure proper less is available (busybox's less breaks git pager)
            less
          ];

          shellHook = ''
            # Use real less instead of busybox's (fixes git pager)
            export PAGER="${pkgs.less}/bin/less"

            echo "Xenomorph development environment"
            echo "Zig version: $(zig version)"
            echo ""
            echo "Build targets:"
            echo "  nix build .#xenomorph-x86_64   # x86_64 static"
            echo "  nix build .#xenomorph-aarch64  # aarch64 static"
            echo "  nix build .#xenomorph-armv7    # armv7 static"
            echo ""
            echo "To run QEMU integration test:"
            echo "  nix run .#qemu-test"
          '';
        };
      }
    ) // {
      # Garnix-specific configuration
      garnix = {
        builds = {
          # Only build for x86_64-linux (cross-compilation handles other targets)
          exclude = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" ];
        };
        # Enable KVM for QEMU integration tests
        server.enable = true;
      };
    };
}
