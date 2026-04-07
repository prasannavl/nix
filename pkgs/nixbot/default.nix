{pkgs ? import <nixpkgs> {}}: let
  pkgHelper = import ../../lib/flake/pkg-helper.nix;
  drv = pkgHelper.mkShellScriptDerivation {
    inherit pkgs;
    src = ./.;
    build = pkgs.writeShellApplication {
      name = "nixbot";
      meta = {
        description = "NixOS management bot";
        mainProgram = "nixbot";
      };
      runtimeInputs = with pkgs; [
        age
        coreutils
        findutils
        git
        jq
        nix
        nixos-rebuild-ng
        openssh
        opentofu
      ];
      text = ''
        export NIXBOT_IN_NIX_SHELL=1
        exec ${pkgs.bash}/bin/bash ${./nixbot.sh} "$@"
      '';
    };
  };
in
  drv
