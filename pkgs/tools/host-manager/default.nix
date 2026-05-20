{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
}: let
  drv = pkgHelper.mkShellScriptDerivation {
    inherit pkgs;
    src = ./.;
    build = pkgs.writeShellApplication {
      name = "host-manager";
      meta = {
        description = "Repo host generation and installation helper";
        mainProgram = "host-manager";
      };
      # Keep in sync with runtime_packages in ./host-manager.sh.
      runtimeInputs = with pkgs; [
        age
        alejandra
        coreutils
        disko
        gawk
        gnugrep
        gnused
        jq
        nix
        nixos-install-tools
      ];
      text = ''
        export HOST_MANAGER_IN_NIX_SHELL=1
        exec ${pkgs.bash}/bin/bash ${./host-manager.sh} "$@"
      '';
    };
  };
in
  drv
