# Language implementation; pkg-helper.nix supplies the shared operations.
{common}: let
  inherit (common) commonAutoExcludes deriveProjectName inferBuildSrc joinWords mkAutoFilesPart mkPackageOpsBundle projectFmtGlobal wirePassthru;
in rec {
  goFmt = {paths}: "gofmt -w ${joinWords paths}";
  goFmtCheck = {paths}: ''test -z "$(gofmt -d ${joinWords paths})"'';
  goLint = {paths ? ["./..."]}: "go vet ${joinWords paths}";
  goTest = {paths ? ["./..."]}: "go test ${joinWords paths}";

  projectFmtGo = pkgs: {
    roots ? ["."],
    excludes ? (commonAutoExcludes ++ ["./vendor"]),
  }:
    mkAutoFilesPart {
      inputs = [
        pkgs.go
        pkgs.findutils
      ];
      varName = "go_fmt_files";
      inherit roots excludes;
      extensions = ["*.go"];
      commandBuilder = files: "gofmt -w ${files}";
      writableCopy = true;
    };

  projectCheckFmtGo = pkgs: {
    roots ? ["."],
    excludes ? (commonAutoExcludes ++ ["./vendor"]),
  }:
    mkAutoFilesPart {
      inputs = [
        pkgs.go
        pkgs.findutils
      ];
      varName = "go_check_files";
      inherit roots excludes;
      extensions = ["*.go"];
      commandBuilder = files: ''test -z "$(gofmt -d ${files})"'';
    };

  projectLintGo = pkgs: {paths ? ["./..."]}: {
    inputs = [pkgs.go];
    commands = [(goLint {inherit paths;})];
  };

  projectTestGo = pkgs: {paths ? ["./..."]}: {
    inputs = [pkgs.go];
    commands = [(goTest {inherit paths;})];
  };

  mkGoParts = {
    pkgs,
    src,
    pname ? deriveProjectName src,
    fmtParts ? [
      (projectFmtGlobal {})
      (projectFmtGo pkgs {})
    ],
    fmtCheckParts ? [
      (projectFmtGlobal {})
      (projectCheckFmtGo pkgs {})
    ],
    lintParts ? [
      (projectLintGo pkgs {})
    ],
    testParts ? [
      (projectTestGo pkgs {})
    ],
    fmtCommands ? [],
    lintCommands ? [],
    testCommands ? [],
    checkEnv ? {
      HOME = "$TMPDIR/home";
      XDG_CACHE_HOME = "$TMPDIR/.cache";
      GOCACHE = "$TMPDIR/go-build";
    },
    checkSetupCommands ? [
      ''mkdir -p "$HOME" "$XDG_CACHE_HOME" "$GOCACHE"''
    ],
    devShellPackages ? [
      pkgs.go
      pkgs.gopls
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
      };
      checks = {
        fmt = {
          parts = fmtCheckParts;
          commands = fmtCommands;
        };
        lint = {
          parts = lintParts;
          env = checkEnv;
          commands = checkEnvCommands ++ lintCommands;
        };
        test = {
          parts = testParts;
          env = checkEnv;
          commands = checkEnvCommands ++ testCommands;
        };
      };
    };

  mkGoDerivation = args @ {
    build,
    src ? inferBuildSrc build,
    ...
  }:
    wirePassthru build (mkGoParts ((builtins.removeAttrs args ["build"]) // {inherit src;}));
}
