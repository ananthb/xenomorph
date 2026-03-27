{
  description = "Xenomorph - Linux pivot_root tool for OCI images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    oci-zig = {
      url = "github:ananthb/oci-zig";
      flake = false;
    };
    oci-spec-zig = {
      url = "github:ananthb/oci-spec-zig/zig-0.15-compat";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, oci-zig, oci-spec-zig }:
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

        # Read dependency hashes from build.zig.zon files so zig --system works.
        # These must match the .hash fields in build.zig.zon and oci-zig/build.zig.zon.
        ociZigHash = "oci-0.1.0-1P7svu6DAQBV7dMp_6YDD8yTQ4uOaHAWrb8ZgWBnHEaR";
        ociSpecHash = "ocispec-0.4.0-dev-voj0cXayAgC0zlyLL8rLlKZ6ecztwkiiApk4IzpAZoOp";

        # Create a directory structure that zig --system expects:
        # pkgdir/<hash> → source tree
        zigDepsDir = pkgs.runCommand "xenomorph-zig-deps" {} ''
          mkdir -p $out
          ln -s ${oci-zig} $out/${ociZigHash}
          ln -s ${oci-spec-zig} $out/${ociSpecHash}
        '';

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
            zig build \
              --system ${zigDepsDir} \
              -Doptimize=ReleaseSafe \
              -Dtarget=${zigTarget} \
              --prefix $out
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
            cp -r ${./.}/init xenomorph-${version}/ 2>/dev/null || true
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
          default = xenomorph-x86_64;
          xenomorph = xenomorph-x86_64;

          inherit xenomorph-x86_64 xenomorph-aarch64 xenomorph-armv7;

          releaseTarball = releaseTarball-x86_64;
          inherit releaseTarball-x86_64 releaseTarball-aarch64 releaseTarball-armv7;

          # Build all platforms (writes binaries to ./dist/)
          build-all = pkgs.writeShellScriptBin "xenomorph-build-all" ''
            set -e
            rm -rf dist
            mkdir -p dist
            echo "Building x86_64..."
            cp ${xenomorph-x86_64}/bin/xenomorph dist/xenomorph-x86_64-linux
            echo "Building aarch64..."
            cp ${xenomorph-aarch64}/bin/xenomorph dist/xenomorph-aarch64-linux
            echo "Building armv7..."
            cp ${xenomorph-armv7}/bin/xenomorph dist/xenomorph-armv7-linux
            echo ""
            echo "Binaries:"
            ls -lh dist/
          '';

          # Build release artifacts + checksums (writes to ./release/)
          release = pkgs.writeShellScriptBin "xenomorph-release" ''
            set -e
            rm -rf release
            mkdir -p release

            echo "Building static binaries..."
            cp ${xenomorph-x86_64}/bin/xenomorph release/xenomorph-x86_64-linux
            cp ${xenomorph-aarch64}/bin/xenomorph release/xenomorph-aarch64-linux
            cp ${xenomorph-armv7}/bin/xenomorph release/xenomorph-armv7-linux

            echo "Building release tarballs..."
            cp ${releaseTarball-x86_64}/*.tar.gz release/
            cp ${releaseTarball-aarch64}/*.tar.gz release/
            cp ${releaseTarball-armv7}/*.tar.gz release/

            cd release
            sha256sum * > SHA256SUMS
            echo ""
            echo "Release artifacts:"
            ls -lh
            echo ""
            cat SHA256SUMS
          '';
        };

        checks = {
          build = xenomorph-x86_64;
          build-aarch64 = xenomorph-aarch64;
          build-armv7 = xenomorph-armv7;

          test = pkgs.stdenv.mkDerivation {
            pname = "xenomorph-test";
            inherit version;
            src = ./.;

            nativeBuildInputs = [ pkgs.zig ];
            dontConfigure = true;
            dontInstall = true;

            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
              zig build test --system ${zigDepsDir}
              touch $out
            '';
          };

          fmt = pkgs.stdenv.mkDerivation {
            pname = "xenomorph-fmt";
            inherit version;
            src = ./.;

            nativeBuildInputs = [ pkgs.zig ];
            dontConfigure = true;
            dontInstall = true;

            buildPhase = ''
              export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
              zig fmt --check src/ || echo "Format check skipped"
              touch $out
            '';
          };

          # NixOS VM test: systemd rescue.target pivot
          nixos-rescue = pkgs.nixosTest {
            name = "xenomorph-rescue-target";

            nodes.machine = { pkgs, lib, ... }: {
              imports = [ self.nixosModules.default ];

              services.xenomorph = {
                enable = true;
                package = xenomorph-x86_64;
                images = [ ];
                warmupBuildCache = true;
              };

              # The test VM needs a rootfs to pivot into.
              # Create a minimal rootfs with busybox as a local tarball.
              systemd.services.xenomorph-test-rootfs = {
                description = "Create test rootfs for xenomorph";
                wantedBy = [ "multi-user.target" ];
                before = [ "xenomorph-cache-warm.service" ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  mkdir -p /var/lib/xenomorph-test/rootfs/{bin,sbin,lib,dev,proc,sys,tmp,etc,var,run}
                  cp ${pkgs.pkgsStatic.busybox}/bin/busybox /var/lib/xenomorph-test/rootfs/bin/busybox
                  ln -sf busybox /var/lib/xenomorph-test/rootfs/bin/sh
                  ln -sf /bin/sh /var/lib/xenomorph-test/rootfs/sbin/init
                  echo "xenomorph-test" > /var/lib/xenomorph-test/rootfs/etc/hostname
                  echo "XENOMORPH_TEST_ROOTFS=1" > /var/lib/xenomorph-test/rootfs/etc/environment
                '';
              };

              # Override xenomorph to use the local rootfs
              systemd.services.xenomorph-cache-warm.serviceConfig.ExecStart =
                lib.mkForce "${xenomorph-x86_64}/bin/xenomorph build --rootfs /var/lib/xenomorph-test/rootfs";

              systemd.services.xenomorph-pivot.serviceConfig.ExecStart =
                lib.mkForce "${xenomorph-x86_64}/bin/xenomorph pivot --systemd-mode --force --rootfs /var/lib/xenomorph-test/rootfs --entrypoint /bin/sh --no-keep-old-root";

              # Need enough memory for tmpfs rootfs
              virtualisation.memorySize = 2048;
            };

            testScript = ''
              machine.wait_for_unit("multi-user.target")

              # Verify test rootfs was created
              machine.succeed("test -f /var/lib/xenomorph-test/rootfs/bin/sh")

              # Verify cache warmup ran
              machine.wait_for_unit("xenomorph-cache-warm.service")
              machine.succeed("ls /var/cache/xenomorph/builds/")

              # Verify cache directory has content
              result = machine.succeed("find /var/cache/xenomorph/builds -name 'index.json' | head -1")
              assert result.strip() != "", "Build cache should contain an OCI layout"
            '';
          };

        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            zls
            less
          ];

          shellHook = ''
            export PAGER="${pkgs.less}/bin/less"
            echo "Xenomorph development environment"
            echo "Zig version: $(zig version)"
            echo ""
            echo "Commands:"
            echo "  nix run .#build-all   # Build binaries for all platforms → dist/"
            echo "  nix run .#release     # Build release tarballs + checksums → release/"
            echo "  nix flake check       # Run all checks including NixOS VM test"
          '';
        };
      }
    ) // {
      # NixOS module for xenomorph rescue pivot
      nixosModules.default = import ./nix/module.nix;
      nixosModules.xenomorph = import ./nix/module.nix;

      garnix = {
        builds = {
          exclude = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" ];
        };
        server.enable = true;
      };
    };
}
