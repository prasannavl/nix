{
  pkgs,
  packageSet,
  pkgHelper,
}: let
  repoRoot = ../..;
  packageRuntimeInputs = pkgs.lib.unique (pkgHelper.pkgOpsRuntimeInputs packageSet);
  pkgOpsManifestFile = pkgs.writeText "pkg-ops-manifest.json" (builtins.toJSON (pkgHelper.pkgOpsManifest packageSet));
  formatterPkgs =
    (pkgHelper.repoFmtRuntimeInputs pkgs)
    ++ (with pkgs; [
      bash
      findutils
      git
      nix
      jq
    ])
    ++ packageRuntimeInputs;
  lintPkgs = pkgs.lib.unique (
    formatterPkgs
    ++ (with pkgs; [
      statix
      deadnix
      shellcheck
      actionlint
      markdownlint-cli2
      tflint
    ])
  );
  lintApp = pkgs.writeShellApplication {
    name = "lint";
    meta = {
      description = "Run linters on the repository";
      mainProgram = "lint";
    };
    runtimeInputs = lintPkgs;
    text = ''
      export PKG_OPS_MANIFEST=${pkgOpsManifestFile}
      exec env LINT_IN_NIX_SHELL=1 ${repoRoot}/scripts/lint.sh "$@"
    '';
  };
  formatterApp = pkgs.writeShellApplication {
    name = "fmt";
    meta = {
      description = "Format root-managed files and delegate package formatting to child flakes";
      mainProgram = "fmt";
    };
    runtimeInputs = formatterPkgs;
    text = ''
      export PKG_OPS_MANIFEST=${pkgOpsManifestFile}
      exec env FMT_IN_NIX_SHELL=1 bash ${repoRoot}/scripts/fmt.sh "$@"
    '';
  };
in {
  inherit formatterPkgs lintApp lintPkgs;

  formatter = formatterApp;

  apps = {
    lint = {
      type = "app";
      program = "${lintApp}/bin/${lintApp.meta.mainProgram}";
      inherit (lintApp) meta;
    };
    fmt = {
      type = "app";
      program = "${formatterApp}/bin/${formatterApp.meta.mainProgram}";
      inherit (formatterApp) meta;
    };
  };

  packages = {
    lint = lintApp;
    fmt = formatterApp;
  };
}
