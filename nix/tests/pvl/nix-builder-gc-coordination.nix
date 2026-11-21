{pkgs}: let
  config =
    (import ../../../ab/system/nix/tests/fixture.nix {
      inherit pkgs;
      extraModules = [../../profiles/policy/nix-builder.nix];
    }).config;
in
  assert config.nix.settings.max-jobs == 16;
  assert config.nix.settings.cores == 0;
  assert config.nix.settings.http-connections == 16;
    pkgs.runCommand "pvl-nix-builder-gc-defaults-test" {} ''
      touch "$out"
    ''
