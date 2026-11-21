{
  ab,
  fmtScript,
  lintScript,
  packageSet,
  pkgs,
}: let
  isAvailablePackage = pkg: let
    resolved = builtins.tryEval pkg;
  in
    if !resolved.success
    then false
    else if !pkgs.lib.isDerivation resolved.value
    then false
    else if !((resolved.value.meta or {}) ? platforms)
    then true
    else pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform resolved.value;
  availablePackages = pkgs.lib.filterAttrs (_: isAvailablePackage) packageSet;

  packageOps = rec {
    manifest = ab.package.ops.manifest pkgs availablePackages;
    runtimeInputs = pkgs.lib.unique (ab.package.ops.runtimeInputs pkgs availablePackages);
    manifestFile = pkgs.writeText "pkg-ops-manifest.json" (builtins.toJSON manifest);
  };

  formatterPackages =
    (with pkgs; [
      treefmt
      alejandra
      deno
      opentofu
      shfmt
      bash
      findutils
      git
      nix
      jq
    ])
    ++ packageOps.runtimeInputs;
  lintPackages = pkgs.lib.unique (
    formatterPackages
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
    runtimeInputs = lintPackages;
    text = ''
      export PKG_OPS_MANIFEST=${packageOps.manifestFile}
      exec env LINT_IN_NIX_SHELL=1 bash ${lintScript} "$@"
    '';
  };
  formatterApp = pkgs.writeShellApplication {
    name = "fmt";
    meta = {
      description = "Format root-managed files and delegate package formatting to child flakes";
      mainProgram = "fmt";
    };
    runtimeInputs = formatterPackages;
    text = ''
      export PKG_OPS_MANIFEST=${packageOps.manifestFile}
      exec env FMT_IN_NIX_SHELL=1 bash ${fmtScript} "$@"
    '';
  };
in rec {
  inherit formatterPackages lintPackages packageOps;

  fmt = formatterApp;
  lint = lintApp;
  formatter = fmt;

  apps = {
    lint = {
      type = "app";
      program = "${lint}/bin/${lint.meta.mainProgram}";
      inherit (lint) meta;
    };
    fmt = {
      type = "app";
      program = "${fmt}/bin/${fmt.meta.mainProgram}";
      inherit (fmt) meta;
    };
  };

  packages = {inherit fmt lint;};
}
