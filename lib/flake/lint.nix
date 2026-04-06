{pkgs}: let
  repoRoot = ../..;
  formatterPkgs = with pkgs; [
    treefmt
    alejandra
    cargo
    deno
    opentofu
    rustfmt
  ];
  lintPkgs =
    formatterPkgs
    ++ (with pkgs; [
      git
      jq
      statix
      deadnix
      shellcheck
      actionlint
      markdownlint-cli2
      tflint
    ]);
  lintApp = pkgs.writeShellApplication {
    name = "lint";
    meta = {
      description = "Run linters on the repository";
      mainProgram = "lint";
    };
    runtimeInputs = lintPkgs;
    text = ''
      exec env LINT_IN_NIX_SHELL=1 ${repoRoot}/scripts/lint.sh "$@"
    '';
  };
in {
  inherit formatterPkgs lintApp lintPkgs;

  formatter = pkgs.writeShellApplication {
    name = "treefmt";
    runtimeInputs = formatterPkgs;
    text = "treefmt";
  };

  apps = {
    lint = {
      type = "app";
      program = "${lintApp}/bin/${lintApp.meta.mainProgram}";
      inherit (lintApp) meta;
    };
  };

  packages = {
    lint = lintApp;
  };
}
