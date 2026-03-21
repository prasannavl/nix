{pkgs}: let
  repoRoot = ../..;
  formatterPkgs = with pkgs; [
    treefmt
    alejandra
    deno
    opentofu
  ];
  lintPkgs =
    formatterPkgs
    ++ (with pkgs; [
      git
      statix
      deadnix
      shellcheck
      actionlint
      markdownlint-cli2
      tflint
    ]);
  lintApp = pkgs.writeShellApplication {
    name = "lint";
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

  app = {
    type = "app";
    program = "${lintApp}/bin/lint";
  };

  apps = {
    lint = {
      type = "app";
      program = "${lintApp}/bin/lint";
    };
  };

  packages = {
    lint = lintApp;
  };
}
