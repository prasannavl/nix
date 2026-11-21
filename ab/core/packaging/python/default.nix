# Language implementation; pkg-helper.nix supplies the shared operations.
{common}: let
  inherit (common) deriveProjectName inferBuildSrc joinWords mkPackageOpsBundle projectFmtGlobal wirePassthru;
in rec {
  ruffFmt = {paths}: "ruff format ${joinWords paths}";
  ruffFmtCheck = {paths}: "ruff format --check ${joinWords paths}";
  ruffLint = {paths}: "ruff check ${joinWords paths}";
  ruffLintFix = {paths}: "ruff check --fix ${joinWords paths}";

  projectFmtRuff = pkgs: {paths ? ["."]}: {
    inputs = [pkgs.ruff];
    commands = [(ruffFmt {inherit paths;})];
  };

  projectCheckFmtRuff = pkgs: {paths ? ["."]}: {
    inputs = [pkgs.ruff];
    commands = [(ruffFmtCheck {inherit paths;})];
  };

  projectLintRuff = pkgs: {paths ? ["."]}: {
    inputs = [pkgs.ruff];
    commands = [(ruffLint {inherit paths;})];
  };

  projectLintFixRuff = pkgs: {paths ? ["."]}: {
    inputs = [pkgs.ruff];
    commands = [(ruffLintFix {inherit paths;})];
  };

  mkPythonParts = {
    pkgs,
    src,
    pname ? deriveProjectName src,
    fmtParts ? [
      (projectFmtGlobal {})
      (projectFmtRuff pkgs {})
    ],
    fmtCheckParts ? [
      (projectFmtGlobal {})
      (projectCheckFmtRuff pkgs {})
    ],
    lintParts ? [
      (projectLintRuff pkgs {})
    ],
    lintFixParts ? [
      (projectLintFixRuff pkgs {})
    ],
    fmtCommands ? [],
    lintCommands ? ["ruff check ."],
    lintFixCommands ? ["exec ruff check --fix ."],
    checkEnv ? {
      HOME = "$TMPDIR/home";
      XDG_CACHE_HOME = "$TMPDIR/.cache";
      RUFF_CACHE_DIR = "$TMPDIR/.ruff_cache";
    },
    checkSetupCommands ? [
      ''mkdir -p "$HOME" "$XDG_CACHE_HOME" "$RUFF_CACHE_DIR"''
    ],
    devShellPackages ? [
      pkgs.python3
      pkgs.python3Packages.hatchling
      pkgs.ruff
    ],
  }: let
    checkEnvCommands = checkSetupCommands;
  in
    mkPackageOpsBundle {
      inherit pkgs src pname devShellPackages;
      apps = {
        fmt = {
          parts = fmtParts;
        };
        "lint-fix" = {
          parts = lintFixParts;
          commands = lintFixCommands;
        };
      };
      checks = {
        fmt = {
          parts = fmtCheckParts;
          env = checkEnv;
          commands = checkEnvCommands ++ fmtCommands;
        };
        lint = {
          parts = lintParts;
          env = checkEnv;
          commands = checkEnvCommands ++ lintCommands;
        };
      };
    };

  mkPythonDerivation = args @ {
    build,
    src ? inferBuildSrc build,
    ...
  }:
    wirePassthru build (mkPythonParts ((builtins.removeAttrs args ["build"]) // {inherit src;}));
}
