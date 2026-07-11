{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
}: let
  tests = import ./tests {pkgs = pkgs;};
  migrationManager = pkgs.writeShellApplication {
    name = "migration-manager";
    runtimeInputs = with pkgs; [
      age
      coreutils
      findutils
      gnugrep
      jq
      nix
      openssh
      systemd
    ];
    text = builtins.readFile ./migration-manager.sh;
  };

  migrationManagerHelper = pkgs.writeShellApplication {
    name = "migration-manager-helper";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      jq
      systemd
      util-linux
    ];
    text = builtins.readFile ./helper.sh;
  };
  build = pkgs.symlinkJoin {
    name = "migration-manager";
    paths = [
      migrationManager
      migrationManagerHelper
    ];
    postBuild = ''
      install -Dm0644 ${./migration-manager.bash} \
        $out/share/bash-completion/completions/migration-manager
    '';
    meta = {
      description = "Runtime migration gate control for repo-managed services";
      platforms = pkgs.lib.platforms.linux;
      mainProgram = "migration-manager";
    };
  };
in
  pkgHelper.mkShellScriptDerivation {
    inherit build pkgs;
    src = ./.;
    extraPassthru = {
      tests = tests;
    };
  }
