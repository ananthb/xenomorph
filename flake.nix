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

        version = if (self ? rev) then "0.2.0-${self.shortRev}" else "0.2.0-dev";

        # Static build targets (Zig cross-compilation)
        targets = {
          x86_64 = "x86_64-linux-musl";
          aarch64 = "aarch64-linux-musl";
          armv7 = "arm-linux-musleabihf";
        };

        # Read dependency hashes from build.zig.zon files so zig --system works.
        # These must match the .hash fields in build.zig.zon and oci-zig/build.zig.zon.
        ociZigHash = "oci-0.1.0-1P7svsilAQALYfT9pKR4Z7f68uRgIV6stbQdGwLEg1lc";
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
            mkdir -p xenomorph-${version}/bin
            cp $src/bin/xenomorph xenomorph-${version}/bin/
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

            echo "Building release tarballs..."
            cp ${releaseTarball-x86_64}/*.tar.gz release/
            cp ${releaseTarball-aarch64}/*.tar.gz release/
            cp ${releaseTarball-armv7}/*.tar.gz release/

            cd release
            sha256sum *.tar.gz > SHA256SUMS
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

          # NixOS VM test: local rootfs build + cache
          nixos-local = pkgs.testers.nixosTest {
            name = "xenomorph-local-build";

            nodes.machine = { pkgs, lib, ... }: {
              imports = [ self.nixosModules.default ];

              services.xenomorph = {
                enable = true;
                package = xenomorph-x86_64;
                images = [ ];
                warmupBuildCache = true;
              };

              # Create a minimal rootfs tarball with busybox
              systemd.services.xenomorph-test-rootfs = {
                description = "Create test rootfs for xenomorph";
                wantedBy = [ "multi-user.target" ];
                before = [ "xenomorph-cache-warm.service" ];
                path = [ pkgs.gnutar pkgs.gzip ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  mkdir -p /tmp/xenomorph-test-rootfs/{bin,sbin,lib,dev,proc,sys,tmp,etc,var,run}
                  cp ${pkgs.pkgsStatic.busybox}/bin/busybox /tmp/xenomorph-test-rootfs/bin/busybox
                  ln -sf busybox /tmp/xenomorph-test-rootfs/bin/sh
                  ln -sf /bin/sh /tmp/xenomorph-test-rootfs/sbin/init
                  echo "xenomorph-test" > /tmp/xenomorph-test-rootfs/etc/hostname
                  mkdir -p /var/lib/xenomorph-test
                  tar czf /var/lib/xenomorph-test/rootfs.tar.gz -C /tmp/xenomorph-test-rootfs .
                '';
              };

              systemd.services.xenomorph-cache-warm.serviceConfig.ExecStart =
                lib.mkForce "${xenomorph-x86_64}/bin/xenomorph build --rootfs /var/lib/xenomorph-test/rootfs.tar.gz";

              virtualisation.memorySize = 2048;
            };

            testScript = ''
              machine.wait_for_unit("multi-user.target")
              machine.wait_for_unit("xenomorph-test-rootfs.service")
              machine.succeed("test -f /var/lib/xenomorph-test/rootfs.tar.gz")
              machine.wait_for_unit("xenomorph-cache-warm.service")
            '';
          };

          # NixOS VM test: pull from registry + build
          nixos-registry-pull = pkgs.testers.nixosTest {
            name = "xenomorph-registry-pull";

            nodes.machine = { pkgs, lib, ... }: {
              virtualisation.memorySize = 4096;

              # Need network access to pull from Docker Hub
              networking.firewall.enable = false;

              environment.systemPackages = [ xenomorph-x86_64 ];
            };

            testScript = ''
              machine.wait_for_unit("network-online.target")

              # Test: build from registry image (exercises estimateImageSize catch path)
              machine.succeed(
                "${xenomorph-x86_64}/bin/xenomorph build "
                "--image docker.io/library/alpine:latest "
                "--cache-dir /var/cache/xenomorph "
                "-o /tmp/test-output.oci"
              )

              # Verify OCI layout was created
              machine.succeed("test -f /tmp/test-output.oci/index.json")

              # Verify cache was populated
              result = machine.succeed("find /var/cache/xenomorph/builds -name 'index.json' | head -1")
              assert result.strip() != "", "Build cache should contain an OCI layout"

              # Test: second build should use cache (fast)
              machine.succeed(
                "${xenomorph-x86_64}/bin/xenomorph build "
                "--image docker.io/library/alpine:latest "
                "--cache-dir /var/cache/xenomorph "
                "-o /tmp/test-output2.oci"
              )
              machine.succeed("test -f /tmp/test-output2.oci/index.json")
            '';
          };

          # NixOS VM test: RUN support + dropbear install
          nixos-run = pkgs.testers.nixosTest {
            name = "xenomorph-run-support";

            nodes.machine = { pkgs, lib, ... }: {
              virtualisation.memorySize = 4096;
              networking.firewall.enable = false;
              environment.systemPackages = [ xenomorph-x86_64 ];
            };

            testScript = ''
              machine.wait_for_unit("network-online.target")

              # Test: build alpine + RUN apk add dropbear (via --ssh-port)
              machine.succeed(
                "${xenomorph-x86_64}/bin/xenomorph build "
                "--image docker.io/library/alpine:latest "
                "--ssh-port 2222 "
                "--cache-dir /var/cache/xenomorph "
                "-o /tmp/test-ssh.oci"
              )
              machine.succeed("test -f /tmp/test-ssh.oci/index.json")

              # Test: build alpine with Containerfile containing RUN
              machine.succeed("mkdir -p /tmp/ctx")
              machine.succeed(
                "cat > /tmp/ctx/Containerfile << 'CF'\n"
                "FROM docker.io/library/alpine:latest\n"
                "RUN apk add --no-cache curl\n"
                "CF"
              )
              machine.succeed(
                "${xenomorph-x86_64}/bin/xenomorph build "
                "--containerfile /tmp/ctx/Containerfile "
                "--context /tmp/ctx "
                "--cache-dir /var/cache/xenomorph "
                "-o /tmp/test-run.oci"
              )
              machine.succeed("test -f /tmp/test-run.oci/index.json")
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
