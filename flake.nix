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

        xenomorph = pkgs.stdenv.mkDerivation {
          pname = "xenomorph";
          inherit version;
          src = ./.;

          nativeBuildInputs = [ pkgs.zig ];

          dontConfigure = true;
          dontInstall = true;

          buildPhase = ''
            runHook preBuild

            export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
            zig build -Doptimize=ReleaseSafe --prefix $out

            runHook postBuild
          '';

          meta = with pkgs.lib; {
            description = "Linux pivot_root tool for OCI images";
            homepage = "https://github.com/ananth/xenomorph";
            license = licenses.gpl3Only;
            platforms = platforms.linux;
            mainProgram = "xenomorph";
          };
        };

        # Release tarball with static binary
        releaseTarball = pkgs.stdenv.mkDerivation {
          pname = "xenomorph-release";
          inherit version;
          src = xenomorph;

          nativeBuildInputs = [ pkgs.gnutar pkgs.gzip ];

          buildPhase = ''
            mkdir -p xenomorph-${version}
            cp -r $src/bin xenomorph-${version}/
            cp ${./.}/README.md xenomorph-${version}/ 2>/dev/null || echo "No README" > xenomorph-${version}/README.md
            cp ${./.}/LICENSE xenomorph-${version}/ 2>/dev/null || echo "MIT License" > xenomorph-${version}/LICENSE
          '';

          installPhase = ''
            mkdir -p $out
            tar -czvf $out/xenomorph-${version}-${system}.tar.gz xenomorph-${version}
          '';
        };

        # Static xenomorph build for QEMU testing (uses musl for static linking)
        xenomorphStatic = pkgs.stdenv.mkDerivation {
          pname = "xenomorph-static";
          inherit version;
          src = ./.;

          nativeBuildInputs = [ pkgs.zig ];

          dontConfigure = true;
          dontInstall = true;

          buildPhase = ''
            runHook preBuild

            export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
            zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl --prefix $out

            runHook postBuild
          '';
        };

      in
      {
        packages = {
          default = xenomorph;
          inherit xenomorph releaseTarball;
        };

        # Checks for Garnix CI
        checks = {
          build = xenomorph;

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
              export XENOMORPH_PATH="${xenomorphStatic}/bin/xenomorph"

              # Build and run the QEMU test
              zig build test-qemu -Doptimize=ReleaseSafe
              ./zig-out/bin/qemu-test

              touch $out
            '';
          };
        };

        # QEMU integration test
        packages.qemu-test = pkgs.writeShellScriptBin "xenomorph-qemu-test" ''
          set -e

          KERNEL_PATH="${pkgs.linuxPackages_latest.kernel}/bzImage"
          BUSYBOX_PATH="${pkgs.pkgsStatic.busybox}/bin/busybox"
          QEMU_PATH="${pkgs.qemu_kvm}/bin/qemu-system-x86_64"

          # Use the statically-linked xenomorph for QEMU testing
          XENOMORPH_PATH="${xenomorphStatic}/bin/xenomorph"

          export KERNEL_PATH BUSYBOX_PATH XENOMORPH_PATH QEMU_PATH

          # Set up Zig cache directory
          export ZIG_GLOBAL_CACHE_DIR="''${XDG_CACHE_HOME:-$HOME/.cache}/zig"

          # Build and run the QEMU test executable
          ${pkgs.zig}/bin/zig build test-qemu -Doptimize=ReleaseSafe
          ./zig-out/bin/qemu-test
        '';

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
            echo "To run QEMU integration test:"
            echo "  nix run .#qemu-test"
            echo "  # or manually:"
            echo "  KERNEL_PATH=/path/to/bzImage BUSYBOX_PATH=${pkgs.pkgsStatic.busybox}/bin/busybox zig build test-qemu && ./zig-out/bin/qemu-test"
          '';
        };
      }
    ) // {
      # Garnix-specific configuration
      garnix = {
        builds = {
          # Only build for x86_64-linux (aarch64-linux lacks native runners)
          exclude = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" ];
        };
        # Enable KVM for QEMU integration tests
        server.enable = true;
      };
    };
}
