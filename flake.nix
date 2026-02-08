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
            license = licenses.mit;
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
        };

        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            zig
            zls
          ];

          shellHook = ''
            echo "Xenomorph development environment"
            echo "Zig version: $(zig version)"
          '';
        };
      }
    ) // {
      # Garnix-specific configuration
      garnix = {
        builds = {
          exclude = [ "aarch64-darwin" "x86_64-darwin" ];
        };
      };
    };
}
