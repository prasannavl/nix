# Language implementation; pkg-helper.nix supplies the shared operations.
{common}: let
  inherit (common) commonAutoExcludes deriveProjectName joinWords mkAutoFilesPart mkPackageOpsBundle projectFmtGlobal wirePassthru;
in rec {
  shfmtFmt = {paths}: "shfmt -w ${joinWords paths}";
  shfmtCheck = {paths}: "shfmt -d ${joinWords paths}";

  projectLintShell = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
    shell ? "bash",
    extraArgs ? ["--external-sources"],
  }:
    mkAutoFilesPart {
      inputs = [
        pkgs.findutils
        pkgs.shellcheck
      ];
      varName = "shell_lint_files";
      inherit roots excludes;
      extensions = ["*.sh"];
      commandBuilder = files: "shellcheck ${joinWords extraArgs} --shell=${shell} ${files}";
    };

  mkShellScriptDerivation = {
    pkgs,
    src,
    build,
    pname ? deriveProjectName src,
    fmtParts ? [
      (projectFmtGlobal {})
    ],
    lintParts ? [
      (projectLintShell pkgs {})
    ],
    lintCommands ? [],
    devShellPackages ? [
      pkgs.shellcheck
      pkgs.shfmt
    ],
    extraPassthru ? {},
  }: let
    bundle = mkPackageOpsBundle {
      inherit pkgs src pname;
      devShellPackages =
        if devShellPackages == []
        then null
        else devShellPackages;
      apps = {
        fmt = {
          parts = fmtParts;
        };
      };
      checks =
        {
          fmt = {
            parts = fmtParts;
          };
        }
        // (
          if lintParts == []
          then {}
          else {
            lint = {
              parts = lintParts;
              commands = lintCommands;
            };
          }
        );
    };
  in
    wirePassthru build ({
        inherit (bundle) fmt pkgOps checks;
      }
      // (
        if builtins.hasAttr "devShell" bundle
        then {inherit (bundle) devShell;}
        else {}
      )
      // extraPassthru);
}
