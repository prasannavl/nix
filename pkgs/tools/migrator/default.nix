{
  pkgs ? import <nixpkgs> {},
  pkgHelper ? import ../../../lib/flake/pkg-helper.nix,
}: let
  tests = import ./tests {pkgs = pkgs;};
  migratorctl = pkgs.writeShellApplication {
    name = "migratorctl";
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
    text = builtins.readFile ./migratorctl.sh;
  };

  migratorHelper = pkgs.writeShellApplication {
    name = "migrator-helper";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      jq
      systemd
    ];
    text = builtins.readFile ./migrator-helper.sh;
  };

  build = pkgs.symlinkJoin {
    name = "migrator";
    paths = [
      migratorctl
      migratorHelper
    ];
    postBuild = ''
      install -Dm0644 ${./migratorctl.bash} \
        $out/share/bash-completion/completions/migratorctl
    '';
    meta = {
      description = "Runtime migration gate control for repo-managed services";
      platforms = pkgs.lib.platforms.linux;
      mainProgram = "migratorctl";
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
