{
  description = "dumb-server (poc-only)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-module.url = "github:l1ne-company/rust-module";
  };

  outputs = { self, nixpkgs, rust-module, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Project constants
      PNAME = "dumb-server";
      PORT = "6969";

      # Build project for each system
      projectFor = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
          rust-module.lib.mkRustProject {
            inherit pkgs PNAME;
            src = ./.;
          };
    in {
      # Standard outputs using rust-module
      packages = forAllSystems (system: {
        default = (projectFor system).package;
      });

      devShells = forAllSystems (system: {
        default = (projectFor system).devShell;
      });

      checks = forAllSystems (system:
        (projectFor system).checks
      );

      # NixOS module with systemd service + nginx
      nixosModules.default = { pkgs, lib, config, ... }:
        let
          cfg = config.services.dumb-server;
        in {
          options.services.dumb-server = {
            enable = lib.mkEnableOption "dumb-server";
            port = lib.mkOption {
              type = lib.types.port;
              default = 6969;
              description = "Port for dumb-server";
            };
          };

          config = lib.mkIf cfg.enable (lib.mkMerge [
            # Systemd service from rust-module
            (rust-module.lib.mkRustSystemdService {
              inherit lib pkgs;
              inherit PNAME;
              PORT = toString cfg.port;
              config = { packages.default = self.packages.${pkgs.system}.default; };
              binaryName = "dumb-server";
              startCommand = "dumb-server";
            })

            # Nginx reverse proxy
            {
              services.nginx = {
                enable = true;
                recommendedProxySettings = true;
                recommendedOptimisation = true;
                virtualHosts.default = {
                  default = true;
                  locations."/".proxyPass = "http://localhost:${toString cfg.port}";
                };
              };

              networking.firewall.allowedTCPPorts = [ 80 cfg.port ];
            }
          ]);
        };
    };
}