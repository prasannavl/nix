{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
}: let
  python = pkgs.python3.withPackages (ps: [
    ps.cryptography
  ]);
  drv = pkgHelper.mkShellScriptDerivation {
    pkgs = pkgs;
    src = ./.;
    build = pkgs.writeShellApplication {
      name = "incus-certs";
      meta = {
        description = "Generate repo-declared Incus client cert, key, and PFX artifacts";
        mainProgram = "incus-certs";
      };
      runtimeInputs = [
        pkgs.age
        pkgs.nix
      ];
      text = ''
        exec ${python}/bin/python ${./incus-certs.py} "$@"
      '';
    };
  };
in
  drv
