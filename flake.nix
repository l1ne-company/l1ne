{
  description = "setup-dev-zig-0-15-1";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
  inputs.one-for-all.url = "github:l1ne-company/one-for-all";

  outputs = { self, nixpkgs, one-for-all }: 
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
      oneForAllLib = one-for-all.lib.mkLib pkgs;

      zigFromTarball = pkgs.stdenv.mkDerivation {
        pname = "zig";
        version = "0.15.1";

        src = pkgs.fetchurl {
          url = "https://ziglang.org/download/0.15.1/zig-x86_64-linux-0.15.1.tar.xz";
          sha256 = "sha256-xhxdpu3uoUylHs1eRSDG9Bie9SUDg9sz0BhIKTv6/gU=";
        };

        dontConfigure = true;
        dontBuild = true;
        dontStrip = true;

        installPhase = ''
	 mkdir -p $out
	 cp -r ./* $out/
	 mkdir -p $out/bin
	 ln -s $out/zig $out/bin/zig
        '';
      };
    in {
      lib = {
        inherit oneForAllLib;
      };

      packages.${system}.default = zigFromTarball;

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          zigFromTarball
        ];

        shellHook = ''
          if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            echo "syncing one-for-all submodule to latest remote commit..."
            git submodule update --init --recursive --remote libs/one-for-all || {
              echo "warning: failed to refresh submodule; continuing with existing checkout"
            }
          fi
        '';
      };
    };
}
