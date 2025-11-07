{
  description = "dumb-server (poc-only)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    one-for-all.url = "git+file:../../../../libs/one-for-all";
  };

  outputs = { self, nixpkgs, one-for-all, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      genSystems = nixpkgs.lib.genAttrs systems;
      contextFor =
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;
          oneForAllLib = one-for-all.lib.mkLib pkgs;
          src = oneForAllLib.cleanCargoSource ./.;
          commonArgs = {
            inherit src;
            strictDeps = true;
            buildInputs = [ ]
              ++ lib.optionals pkgs.stdenv.isDarwin [
                pkgs.libiconv
              ];
          };
          cargoArtifacts = oneForAllLib.buildDepsOnly commonArgs;
        in
        let
          package = oneForAllLib.buildPackage (
            commonArgs
            // {
              inherit cargoArtifacts;
            }
          );
        in {
          inherit package;
          checks = {
            dumb-server = package;
            dumb-server-clippy = oneForAllLib.cargoClippy (
              commonArgs
              // {
                inherit cargoArtifacts;
                cargoClippyExtraArgs = "--all-targets -- --deny warnings";
              }
            );
            dumb-server-fmt = oneForAllLib.cargoFmt {
              inherit src;
            };
            dumb-server-audit = oneForAllLib.cargoAudit {
              inherit src;
            };
          };
        };
    in {
      packages = genSystems (
        system:
        let
          ctx = contextFor system;
        in {
          default = ctx.package;
          dumb-server = ctx.package;
        }
      );

      checks = genSystems (system: (contextFor system).checks);
    };
}
