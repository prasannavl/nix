{pkgs}: let
  lib = pkgs.lib;
  expected = pkgs.callPackage ../. {};
  # Capture constructor arguments; never execute the service helper.
  stalwart = import ../../../../ab/services/stalwart {
    pkgs =
      pkgs
      // {
        writeShellApplication = args: args;
      };
  };
  apply = stalwart.mkApplyScript {
    cliPackage = expected;
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
