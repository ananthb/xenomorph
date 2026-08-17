{
  description = "xmorph - Linux pivot_root tool for OCI images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    flake-utils.url = "github:numtide/flake-utils";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, git-hooks }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        lib = pkgs.lib;

        version = if (self ? shortRev) then self.shortRev else "dev";

        # nixpkgs ships go 1.26.3; tailscale.com v1.100 (and our go.mod)
        # require 1.26.4. Override by fetching upstream Go source.
        # Bump version + hash via `nix-prefetch-url https://go.dev/dl/goX.Y.Z.src.tar.gz`
        # then `nix hash convert --hash-algo sha256 --to sri <out>`.
        go = pkgs.go.overrideAttrs (_old: rec {
          version = "1.26.4";
          src = pkgs.fetchurl {
            url = "https://go.dev/dl/go${version}.src.tar.gz";
            hash = "sha256-T2aKMvv8ETLmqIH7lowvHa2mMUkqM5IRc1+7JVpCYC0=";
          };
        });

        buildGoModule = pkgs.buildGoModule.override { inherit go; };

        # vendorHash is reproducible from go.mod + go.sum. Update by
        # setting `vendorHash = lib.fakeHash` and rebuilding — Nix will
        # print the expected hash, which you paste back here.
        vendorHash = "sha256-dxdoM+2hzuX7/Qg20ETTEeIXMKgukh7/HkiHtup6laY=";

        # From-source build for `nix build` / `nix run`. Release artifacts
        # come from goreleaser (see .goreleaser.yaml); this derivation feeds
        # the NixOS module + tests.
        xmorph = buildGoModule {
          pname = "xmorph";
          inherit version vendorHash;
          src = ./.;
          env.CGO_ENABLED = "0";
          subPackages = [ "cmd/xmorph" ];
          ldflags = [ "-s" "-w" "-X main.version=${version}" ];
          # Sandbox can't exercise the pivot/mount paths; tests run in CI.
          doCheck = false;
          meta = with lib; {
            description = "Linux pivot_root tool for OCI images";
            homepage = "https://github.com/ananthb/xmorph";
            license = licenses.agpl3Only;
            platforms = platforms.linux;
            mainProgram = "xmorph";
          };
        };

        # Integration test binaries that need a real kernel + root to run
        # (mount namespaces, pivot_root). They are compiled here but executed
        # inside the NixOS VM test below — the nix build sandbox can't do
        # mounts, and GitHub CI has no Apple `container`. Developers on macOS
        # can run the same binaries under `container`; see docs/testing.md.
        xmorphIntegrationTests = buildGoModule {
          pname = "xmorph-integration-tests";
          inherit version vendorHash;
          src = ./.;
          env.CGO_ENABLED = "0";
          doCheck = false;
          buildPhase = ''
            runHook preBuild
            for pkg in pivot oci; do
              go test -c -o "xmorph-$pkg.test" "./internal/$pkg"
            done
            runHook postBuild
          '';
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            install -m555 xmorph-*.test "$out/bin/"
            runHook postInstall
          '';
        };

        # xmorphLint: gofmt + go vet gate. Exposed as `apps.lint` so the
        # pre-commit hook and CI both go through `nix run .#lint`.
        xmorphLint = pkgs.writeShellApplication {
          name = "xmorph-lint";
          runtimeInputs = [ go ];
          text = ''
            unformatted="$(gofmt -l .)"
            if [ -n "$unformatted" ]; then
              echo "gofmt found unformatted files:" >&2
              echo "$unformatted" >&2
              echo "Run \`gofmt -w .\` to fix." >&2
              exit 1
            fi
            # vet has to run against Linux because most packages use
            # syscall/unix Linux-only symbols. Cross-vet from any host.
            GOOS=linux CGO_ENABLED=0 go vet ./...
          '';
        };

        # xmorphTest: `go test ./...` against Linux. Skipped pure-Go-only
        # packages would also be fine, but cross-test compiles all of them
        # against linux so it's a real check.
        xmorphTest = pkgs.writeShellApplication {
          name = "xmorph-test";
          runtimeInputs = [ go ];
          # `go test` can't *run* Linux binaries on darwin, but it can
          # compile-only-check with -c. On Linux, run for real.
          text = if pkgs.stdenv.isLinux then ''
            CGO_ENABLED=0 exec go test ./...
          '' else ''
            # Native macOS test for pure-Go packages, plus compile check
            # of every package targeted at Linux.
            go test ./internal/config/... ./internal/log/... ./internal/helpers/...
            tmp=$(mktemp -d)
            trap 'rm -rf "$tmp"' EXIT
            GOOS=linux CGO_ENABLED=0 go build -o "$tmp/xmorph" ./cmd/xmorph
            echo "linux cross-compile OK ($tmp/xmorph)"
          '';
        };

        # xmorphBuild orchestrates lint + test as a single command;
        # this is what CI runs and what contributors invoke before
        # pushing. The name is "build" in the verification sense — the
        # source-built binary lives under `packages.xmorph`.
        xmorphBuild = pkgs.writeShellApplication {
          name = "xmorph-build";
          runtimeInputs = [ xmorphLint xmorphTest ];
          text = ''
            xmorph-lint
            xmorph-test
          '';
        };

        pre-commit = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            check-merge-conflicts.enable = true;
            check-toml.enable = true;
            check-yaml.enable = true;
            detect-private-keys.enable = true;
            end-of-file-fixer.enable = true;
            trim-trailing-whitespace.enable = true;
            gofmt.enable = true;
            # govet is run via `nix run .#lint` (it needs GOOS=linux); the
            # built-in govet hook runs against host OS and fails on darwin.
          };
        };

      in
      {
        packages = {
          default = xmorph;
          inherit xmorph;
        };

        apps = {
          lint = {
            type = "app";
            program = "${xmorphLint}/bin/xmorph-lint";
          };
          test = {
            type = "app";
            program = "${xmorphTest}/bin/xmorph-test";
          };
          build = {
            type = "app";
            program = "${xmorphBuild}/bin/xmorph-build";
          };
        };

        checks = let
          lifecycleTests = import ./nix/tests/lifecycle.nix {
            inherit pkgs;
            lib = pkgs.lib;
            xmorph-package = xmorph;
          };
        in lib.optionalAttrs pkgs.stdenv.isLinux {
          # Source build is the canonical sanity check.
          build = xmorph;

          # NixOS VM test: local rootfs build + cache
          nixos-local = pkgs.testers.nixosTest {
            name = "xmorph-local-build";

            nodes.machine = { pkgs, lib, ... }: {
              imports = [ self.nixosModules.default ];

              services.xmorph = {
                enable = true;
                package = xmorph;
                images = [ ];
                warmupBuildCache = true;
              };

              # Create a minimal rootfs tarball with busybox
              systemd.services.xmorph-test-rootfs = {
                description = "Create test rootfs for xmorph";
                wantedBy = [ "multi-user.target" ];
                before = [ "xmorph-cache-warm.service" ];
                path = [ pkgs.gnutar pkgs.gzip ];
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  mkdir -p /tmp/xmorph-test-rootfs/{bin,sbin,lib,dev,proc,sys,tmp,etc,var,run}
                  cp ${pkgs.pkgsStatic.busybox}/bin/busybox /tmp/xmorph-test-rootfs/bin/busybox
                  ln -sf busybox /tmp/xmorph-test-rootfs/bin/sh
                  ln -sf /bin/sh /tmp/xmorph-test-rootfs/sbin/init
                  echo "xmorph-test" > /tmp/xmorph-test-rootfs/etc/hostname
                  mkdir -p /var/lib/xmorph-test
                  tar czf /var/lib/xmorph-test/rootfs.tar.gz -C /tmp/xmorph-test-rootfs .
                '';
              };

              systemd.services.xmorph-cache-warm.serviceConfig.ExecStart =
                lib.mkForce "${xmorph}/bin/xmorph build --rootfs /var/lib/xmorph-test/rootfs.tar.gz";

              virtualisation.memorySize = 2048;
            };

            testScript = ''
              machine.wait_for_unit("multi-user.target")
              machine.wait_for_unit("xmorph-test-rootfs.service")
              machine.succeed("test -f /var/lib/xmorph-test/rootfs.tar.gz")
              machine.wait_for_unit("xmorph-cache-warm.service")
            '';
          };

          # NixOS VM test: real pivot_root + mount ordering on a live kernel.
          # Runs the pivot/oci integration test binaries as root inside the VM
          # — this is the project's real-kernel coverage of the pivot path
          # (the nix sandbox can't do mount namespaces). Guards the
          # mount-ordering fix: essentials must stay visible after the pivot.
          nixos-pivot = pkgs.testers.nixosTest {
            name = "xmorph-pivot-integration";

            nodes.machine = { ... }: {
              environment.systemPackages = [ xmorphIntegrationTests ];
              virtualisation.memorySize = 2048;
            };

            testScript = ''
              machine.wait_for_unit("multi-user.target")
              # pivot_root + mount-ordering (needs root + CAP_SYS_ADMIN).
              machine.succeed("xmorph-pivot.test -test.v")
              # tar-extraction containment + setuid, exercised as root — the
              # privilege level at which a symlink escape would actually bite.
              machine.succeed("xmorph-oci.test -test.v")
            '';
          };

          # End-to-end lifecycle: does the machine survive its own pivot?
          # nixos-pivot proves pivot_root works; these prove the box is still
          # there afterwards, which is the property that actually regressed.
          nixos-lifecycle-idle = lifecycleTests.idle-stays-up;
          nixos-lifecycle-exit-reboots = lifecycleTests.exit-reboots;
          nixos-lifecycle-preflight = lifecycleTests.shell-refused-preflight;

          # NixOS VM test: headscale integration (offline, ~2-3 min)
          nixos-headscale = import ./nix/tests/headscale.nix {
            inherit pkgs;
            lib = pkgs.lib;
            xmorph-package = xmorph;
          };
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            go
            pkgs.gopls
            pkgs.gotools
            pkgs.golangci-lint
            # Release pipeline is driven by goreleaser. See .goreleaser.yaml.
            pkgs.goreleaser
            pkgs.cosign
            pkgs.less
          ];

          shellHook = ''
            ${pre-commit.shellHook}
            export PAGER="${pkgs.less}/bin/less"
            echo "xmorph development environment"
            echo "Go version: $(go version)"
            echo ""
            echo "Commands:"
            echo "  nix run .#build               # lint + test (what CI runs)"
            echo "  nix build .#xmorph            # build binary via nix"
            echo "  goreleaser build --snapshot   # smoke-test the release pipeline"
            echo "  nix flake check               # all checks + NixOS VM tests"
          '';
        };
      }
    ) // {
      # NixOS module for xmorph rescue pivot
      nixosModules.default = import ./nix/module.nix;
      nixosModules.xmorph = import ./nix/module.nix;
    };
}
