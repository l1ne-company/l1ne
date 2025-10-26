{
  description = "setup-dev-zig-0-15-1";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";

  outputs = { self, nixpkgs }: 
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };

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
      packages.${system}.default = zigFromTarball;

      devShells.${system}.default = pkgs.mkShell {
        packages = [ zigFromTarball ];
      };
    };
}
