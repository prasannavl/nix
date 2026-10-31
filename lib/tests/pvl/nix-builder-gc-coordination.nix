{pkgs}: let
  config = (import ../fixtures/nix-builder-gc-coordination.nix {pkgs = pkgs;}).config;
in
  assert config.nix.settings.max-jobs == 16;
  assert config.nix.settings.cores == 0;
  assert config.nix.settings.http-connections == 16;
    pkgs.runCommand "pvl-nix-builder-gc-defaults-test" {} ''
      touch "$out"
    ''
