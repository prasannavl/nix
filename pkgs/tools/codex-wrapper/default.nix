{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
  codex-unwrapped ? pkgs.unstable.codex,
}: let
  cr = pkgs.writeShellApplication {
    name = "cr";
    runtimeInputs = [
      pkgs.bubblewrap
      pkgs.coreutils
    ];
    text = ''
      export CODEX_REAL=${pkgs.lib.getExe codex-unwrapped}
      export CODEX_WRAPPER_NAME=''${CODEX_WRAPPER_NAME:-cr}
      exec ${pkgs.bash}/bin/bash ${./codex-wrapper.sh} "$@"
    '';
  };
  cra = pkgs.writeShellApplication {
    name = "cra";
    runtimeInputs = [];
    text = ''
      export CODEX_WRAPPER_NAME=cra
      exec ${cr}/bin/cr -u "$@"
    '';
  };
  drv = pkgHelper.mkShellScriptDerivation {
    pkgs = pkgs;
    src = ./.;
    build = pkgs.symlinkJoin {
      name = "codex-wrapper";
      paths = [
        cr
        cra
      ];
      meta = {
        description = "Local Codex CLI wrapper with auth-slot and unrestricted-mode shortcuts";
        platforms = pkgs.lib.platforms.linux;
        mainProgram = "cr";
      };
    };
  };
in
  drv
