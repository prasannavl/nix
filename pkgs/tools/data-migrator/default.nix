{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
  nixbot ? pkgs.callPackage ../nixbot/default.nix {inherit pkgHelper;},
  migrator ? pkgs.callPackage ../migrator/default.nix {inherit pkgHelper;},
}: let
  lib = pkgs.lib;
  python = pkgs.python3.withPackages (ps: [
    ps.pyyaml
  ]);
  yaml = pkgs.formats.yaml {};
  profiles = import ./profiles.nix;
  profileFiles = pkgs.linkFarm "data-migrator-profiles" (
    lib.mapAttrsToList (name: value: {
      name = "${name}.yaml";
      path = yaml.generate "${name}.yaml" value;
    })
    profiles
  );
  drv = pkgHelper.mkShellScriptDerivation {
    pkgs = pkgs;
    src = ./.;
    build = pkgs.writeShellApplication {
      name = "data-migrator";
      meta = {
        description = "Repo data migration helper for drained host cutovers";
        platforms = pkgs.lib.platforms.linux;
        mainProgram = "data-migrator";
      };
      runtimeInputs = with pkgs; [
        coreutils
        findutils
        git
        gnutar
        incus
        migrator
        nix
        openssh
        rsync
        nixbot
      ];
      text = ''
        export DATA_MIGRATOR_CONFIG_DIR=${profileFiles}
        exec ${python}/bin/python ${./data-migrator.py} "$@"
      '';
    };
  };
in
  drv
