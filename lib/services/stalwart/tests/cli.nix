{pkgs}: let
  lib = pkgs.lib;
  expected = pkgs.callPackage ../../../ext/stalwart-cli {};
  # Capture constructor arguments; never execute the service helper.
  stalwart = import ../. {
    pkgs =
      pkgs
      // {
        writeShellApplication = args: {
          overrideAttrs = _: args;
        };
      };
  };
  apply = stalwart.mkApplyScript {
    configHostPath = "/fixture/config.json";
    dataDir = "/fixture/data";
    image = "fixture/stalwart:unused";
    planHostPath = "/fixture/plan.json";
  };
in
  assert lib.assertMsg (pkgs.stalwart-cli.drvPath == expected.drvPath)
  "Stalwart CLI must use the repository pin";
  assert lib.assertMsg (apply.runtimeEnv.STALWART_CLI_BIN == "${expected}/bin/stalwart-cli")
  "Stalwart helper must select the pinned CLI";
    pkgs.runCommand "stalwart-cli-selection-test" {} ''
      touch "$out"
    ''
