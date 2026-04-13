let
  joinWords = parts:
    builtins.concatStringsSep " " (builtins.filter (part: part != "") parts);

  joinLines = lines:
    builtins.concatStringsSep "\n" (builtins.filter (line: line != "") lines);

  exportEnv = env:
    joinLines (builtins.attrValues (builtins.mapAttrs (name: value: "export ${name}=${builtins.toJSON value}") env));

  repoRoot = builtins.toString ../..;

  stripPrefix = prefix: str: let
    prefixLen = builtins.stringLength prefix;
  in
    if builtins.substring 0 prefixLen str == prefix
    then builtins.substring prefixLen (builtins.stringLength str - prefixLen) str
    else str;

  deriveProjectPath = src:
    stripPrefix "${repoRoot}/" (builtins.toString src);

  deriveProjectName = src:
    builtins.baseNameOf (builtins.toString src);

  shellWords = parts:
    builtins.concatStringsSep " " (map builtins.toJSON parts);

  attrIf = condition: name: value:
    if condition
    then
      builtins.listToAttrs [
        {
          name = name;
          value = value;
        }
      ]
    else {};

  shellArrayRef = varName:
    builtins.concatStringsSep "" [
      "\"''\${"
      varName
      "[@]}\""
    ];

  commonAutoExcludes = [
    "./.git"
    "./.direnv"
    "./result"
    "./node_modules"
    "./dist"
    "./build"
    "./coverage"
    "./.next"
    "./target"
    "./.venv"
    "./venv"
  ];

  biomeExtensions = [
    "*.js"
    "*.jsx"
    "*.mjs"
    "*.cjs"
    "*.ts"
    "*.tsx"
    "*.css"
    "*.html"
  ];

  biomeInputs = pkgs: [
    pkgs.biome
    pkgs.findutils
  ];

  buildFindSnippet = {
    varName,
    roots ? ["."],
    extensions,
    excludes ? [],
  }: let
    pruneExpr =
      if excludes == []
      then ""
      else
        "\\( "
        + builtins.concatStringsSep " -o " (map (path: "-path ${builtins.toJSON path}") excludes)
        + " \\) -prune -o ";
    nameExpr =
      builtins.concatStringsSep " -o " (map (ext: "-name ${builtins.toJSON ext}") extensions);
  in ''
    mapfile -d $'\0' -t ${varName} < <(
      find ${shellWords roots} ${pruneExpr}-type f \( ${nameExpr} \) -print0
    )
  '';

  buildAutoFilesSnippet = {
    varName,
    roots ? ["."],
    extensions,
    excludes ? [],
  }: let
    extCase =
      builtins.concatStringsSep "\n"
      (map (ext:
        builtins.replaceStrings ["*"] [""] ''
          ${ext})
            auto_files+=("$path")
            ;;
        '')
      extensions);
    excludeCase =
      if excludes == []
      then ""
      else
        builtins.concatStringsSep "\n"
        (map (path: "${path}|${path}/*) continue ;;") excludes);
    findSnippet = buildFindSnippet {
      inherit varName roots extensions excludes;
    };
  in ''
    auto_files=()
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
      while IFS= read -r -d $'\0' path; do
        case "$path" in
          ${excludeCase}
        esac
        case "$path" in
          ${extCase}
        esac
      done < <(git ls-files -z --cached --others --exclude-standard -- ${shellWords roots})
      ${varName}=("''${auto_files[@]}")
    else
      ${findSnippet}
    fi
  '';

  mkCheckFn = build: args:
    build.overrideAttrs (old: {
      pname = "${old.pname}-${args.name}";
      nativeBuildInputs =
        (old.nativeBuildInputs or [])
        ++ (args.nativeBuildInputs or []);
      inherit (args) buildPhase;
      installPhase = "touch $out";
      dontInstall = false;
    });
in rec {
  emptyParts = {
    inputs = [];
    env = {};
    repoFmtPaths = [];
    commands = [];
    writableCopy = false;
  };

  mergeParts = parts:
    builtins.foldl'
    (acc: part: {
      inputs = acc.inputs ++ (part.inputs or []);
      env = acc.env // (part.env or {});
      repoFmtPaths =
        acc.repoFmtPaths
        ++ (part.repoFmtPaths or []);
      commands = acc.commands ++ (part.commands or []);
      writableCopy = acc.writableCopy || (part.writableCopy or false);
    })
    emptyParts
    parts;

  mkCheck = mkCheckFn;

  mkChecks = build: checks:
    builtins.mapAttrs (name: args:
      if name == "build"
      then build
      else mkCheckFn build ({name = name;} // args))
    checks;

  alejandraFmt = {paths}: "alejandra ${joinWords paths}";
  alejandraCheck = {paths}: "alejandra --check ${joinWords paths}";

  denoFmt = {paths}: "deno fmt ${joinWords paths}";
  denoFmtCheck = {paths}: "deno fmt --check ${joinWords paths}";

  shfmtFmt = {paths}: "shfmt -w ${joinWords paths}";
  shfmtCheck = {paths}: "shfmt -d ${joinWords paths}";

  biomeFmt = {paths}: "biome format --write ${joinWords paths}";
  biomeFmtCheck = {paths}: "biome check --formatter-enabled=true --linter-enabled=false ${joinWords paths}";
  biomeLint = {paths ? ["."]}: "biome check ${joinWords paths}";
  biomeLintFix = {paths ? ["."]}: "biome check --write ${joinWords paths}";

  ruffFmt = {paths}: "ruff format ${joinWords paths}";
  ruffFmtCheck = {paths}: "ruff format --check ${joinWords paths}";
  ruffLint = {paths}: "ruff check ${joinWords paths}";
  ruffLintFix = {paths}: "ruff check --fix ${joinWords paths}";

  goFmt = {paths}: "gofmt -w ${joinWords paths}";
  goFmtCheck = {paths}: ''test -z "$(gofmt -d ${joinWords paths})"'';
  goLint = {paths ? ["./..."]}: "go vet ${joinWords paths}";
  goTest = {paths ? ["./..."]}: "go test ${joinWords paths}";

  repoFmtRuntimeInputs = pkgs: [
    pkgs.treefmt
    pkgs.alejandra
    pkgs.deno
    pkgs.opentofu
    pkgs.shfmt
  ];

  repoFmtAppCommand = {paths}: "treefmt --quiet --on-unmatched=debug --config-file \"$repo_root/treefmt.toml\" --tree-root \"$repo_root\" ${joinWords paths}";

  repoFmtCheckCommand = {paths}: "treefmt --quiet --on-unmatched=debug --fail-on-change --config-file ${../../treefmt.toml} --tree-root . ${joinWords paths}";

  repoFmtCheckEnv = env:
    {
      HOME = "$TMPDIR/home";
      XDG_CACHE_HOME = "$TMPDIR/.cache";
    }
    // env;

  projectFmtGlobal = {paths ? ["."]}: {
    repoFmtPaths = paths;
    writableCopy = true;
  };

  mkAutoFilesPart = {
    inputs,
    varName,
    extensions,
    commandBuilder,
    roots ? ["."],
    excludes ? commonAutoExcludes,
    writableCopy ? false,
  }: let
    part = {
      inherit inputs;
      commands = [
        (buildAutoFilesSnippet {
          inherit varName roots excludes extensions;
        })
        ''
          if [ "''${#${varName}[@]}" -gt 0 ]; then
            ${commandBuilder (shellArrayRef varName)}
          fi
        ''
      ];
    };
  in
    if writableCopy
    then part // {writableCopy = true;}
    else part;

  projectFmtBiome = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
  }:
    mkAutoFilesPart {
      inputs = biomeInputs pkgs;
      varName = "biome_files";
      inherit roots excludes;
      extensions = biomeExtensions;
      commandBuilder = files: "biome format --write ${files}";
      writableCopy = true;
    };

  projectLintBiome = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
  }:
    mkAutoFilesPart {
      inputs = biomeInputs pkgs;
      varName = "biome_lint_files";
      inherit roots excludes;
      extensions = biomeExtensions;
      commandBuilder = files: "biome check ${files}";
      writableCopy = true;
    };

  projectCheckFmtBiome = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
  }:
    mkAutoFilesPart {
      inputs = biomeInputs pkgs;
      varName = "biome_fmt_check_files";
      inherit roots excludes;
      extensions = biomeExtensions;
      commandBuilder = files: "biome check --formatter-enabled=true --linter-enabled=false ${files}";
    };

  projectLintFixBiome = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
  }:
    mkAutoFilesPart {
      inputs = biomeInputs pkgs;
      varName = "biome_fix_files";
      inherit roots excludes;
      extensions = biomeExtensions;
      commandBuilder = files: "biome check --write ${files}";
      writableCopy = true;
    };

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

  projectFmtRust = pkgs: {cargoArgs ? []}: {
    inputs = [
      pkgs.cargo
      pkgs.rustfmt
    ];
    commands = [(rustFmtCommand cargoArgs)];
  };

  projectLintFixRust = pkgs: {
    cargoArgs ? [],
    lintArgs ? ["--" "-D" "warnings"],
  }: {
    inputs = [
      pkgs.cargo
      pkgs.clippy
      pkgs.rustc
    ];
    commands = [(rustClippyFixCommand cargoArgs lintArgs)];
  };

  mkStdApp = pkgs: {
    kind,
    src,
    pname ? deriveProjectName src,
    description ?
      if kind == "fmt"
      then "Format ${pname}"
      else if kind == "lint-fix"
      then "Apply lint fixes for ${pname}"
      else if kind == "dev"
      then "Run the ${pname} development workflow"
      else "${pname} ${kind}",
    parts ? [],
    runtimeInputs ? [],
    env ? {},
    repoFmtPaths ? [],
    commands ? [],
  }:
    mkProjectCommandsApp pkgs {
      name = "${pname}-${kind}";
      description = description;
      src = src;
      parts = parts;
      runtimeInputs = runtimeInputs;
      env = env;
      repoFmtPaths = repoFmtPaths;
      commands = commands;
    };

  mkStdCheck = pkgs: {
    kind,
    src,
    pname ? deriveProjectName src,
    parts ? [],
    nativeBuildInputs ? [],
    env ? {},
    repoFmtPaths ? [],
    commands ? [],
  }:
    mkProjectCommandsCheck pkgs {
      name = "${pname}-${kind}";
      src = src;
      parts = parts;
      nativeBuildInputs = nativeBuildInputs;
      env = env;
      repoFmtPaths = repoFmtPaths;
      commands = commands;
    };

  resolveProjectOp = pkgs: {
    parts ? [],
    extraInputs ? [],
    env ? {},
    repoFmtPaths ? [],
    commands ? [],
    forCheck ? false,
  }: let
    mergedParts = mergeParts (
      parts
      ++ [
        {
          inputs = extraInputs;
          inherit env repoFmtPaths commands;
        }
      ]
    );
    needsRepoFmt = mergedParts.repoFmtPaths != [];
    effectiveEnv =
      if forCheck && needsRepoFmt
      then repoFmtCheckEnv mergedParts.env
      else mergedParts.env;
    commandPrefix =
      if !needsRepoFmt
      then []
      else if forCheck
      then [
        ''mkdir -p "$HOME" "$XDG_CACHE_HOME"''
        (repoFmtCheckCommand {
          paths = mergedParts.repoFmtPaths;
        })
      ]
      else [
        (repoFmtAppCommand {
          paths = mergedParts.repoFmtPaths;
        })
      ];
  in {
    runtimeInputs =
      mergedParts.inputs
      ++ (
        if needsRepoFmt
        then repoFmtRuntimeInputs pkgs
        else []
      );
    envScript = exportEnv effectiveEnv;
    command = joinLines (commandPrefix ++ mergedParts.commands);
    writableCopy = mergedParts.writableCopy;
  };

  mkProjectAppOp = pkgs: {
    src ? null,
    projectPath ?
      if src != null
      then deriveProjectPath src
      else throw "mkProjectAppOp requires projectPath or src",
    parts ? [],
    runtimeInputs ? [],
    env ? {},
    repoFmtPaths ? [],
    commands ? [],
  }: let
    resolved = resolveProjectOp pkgs {
      inherit parts env repoFmtPaths commands;
      extraInputs = runtimeInputs;
    };
  in {
    path = projectPath;
    inherit (resolved) runtimeInputs envScript command;
  };

  mkProjectCheckOp = pkgs: {
    src,
    projectPath ? deriveProjectPath src,
    parts ? [],
    nativeBuildInputs ? [],
    env ? {},
    repoFmtPaths ? [],
    commands ? [],
  }: let
    resolved = resolveProjectOp pkgs {
      inherit parts env repoFmtPaths commands;
      extraInputs = nativeBuildInputs;
      forCheck = true;
    };
  in {
    path = projectPath;
    inherit (resolved) runtimeInputs envScript command;
  };

  mkStdAppOp = pkgs: {
    src,
    parts ? [],
    runtimeInputs ? [],
    env ? {},
    repoFmtPaths ? [],
    commands ? [],
    ...
  }:
    mkProjectAppOp pkgs {
      inherit src parts runtimeInputs env repoFmtPaths commands;
    };

  mkStdCheckOp = pkgs: {
    src,
    parts ? [],
    nativeBuildInputs ? [],
    env ? {},
    repoFmtPaths ? [],
    commands ? [],
    ...
  }:
    mkProjectCheckOp pkgs {
      inherit src parts nativeBuildInputs env repoFmtPaths commands;
    };

  stripPkgOp = spec:
    if spec == null
    then null
    else builtins.removeAttrs spec ["runtimeInputs"];

  collectPkgOpInputs = pkgOps: let
    appInputs = builtins.concatLists (
      map (
        name: let
          spec = (pkgOps.apps or {}).${name};
        in
          if spec == null
          then []
          else spec.runtimeInputs
      ) (builtins.attrNames (pkgOps.apps or {}))
    );
    checkInputs = builtins.concatLists (
      map (
        name: let
          spec = (pkgOps.checks or {}).${name};
        in
          if spec == null
          then []
          else spec.runtimeInputs
      ) (builtins.attrNames (pkgOps.checks or {}))
    );
  in
    appInputs ++ checkInputs;

  pkgOpsManifest = packageSet: {
    packages = builtins.filter (entry: entry != null) (
      map (
        name: let
          drv = packageSet.${name};
          pkgOps =
            if builtins.isAttrs drv && builtins.hasAttr "passthru" drv
            then (drv.passthru.pkgOps or null)
            else null;
        in
          if pkgOps == null
          then null
          else {
            inherit name;
            path = pkgOps.path;
            apps = builtins.mapAttrs (_: stripPkgOp) (pkgOps.apps or {});
            checks = builtins.mapAttrs (_: stripPkgOp) (pkgOps.checks or {});
          }
      ) (builtins.attrNames packageSet)
    );
  };

  pkgOpsRuntimeInputs = packageSet:
    builtins.concatLists (
      builtins.filter (item: item != null) (
        map (
          name: let
            drv = packageSet.${name};
            pkgOps =
              if builtins.isAttrs drv && builtins.hasAttr "passthru" drv
              then (drv.passthru.pkgOps or null)
              else null;
          in
            if pkgOps == null
            then null
            else collectPkgOpInputs pkgOps
        ) (builtins.attrNames packageSet)
      )
    );

  mkPackageOpsBundle = {
    pkgs,
    src,
    pname ? deriveProjectName src,
    apps ? {},
    checks ? {},
    devShellPackages ? null,
  }: let
    path = deriveProjectPath src;
    appDrvs = builtins.mapAttrs (kind: spec:
      mkStdApp pkgs ({
          inherit kind src pname;
        }
        // spec))
    apps;
    checkDrvs = builtins.mapAttrs (kind: spec:
      mkStdCheck pkgs ({
          inherit kind src pname;
        }
        // spec))
    checks;
    pkgAppOps = builtins.mapAttrs (kind: spec:
      mkStdAppOp pkgs ({
          inherit kind src;
        }
        // spec))
    apps;
    pkgCheckOps = builtins.mapAttrs (kind: spec:
      mkStdCheckOp pkgs ({
          inherit kind src;
        }
        // spec))
    checks;
  in
    appDrvs
    // {
      checks = checkDrvs;
      pkgOps = {
        inherit path;
        apps = pkgAppOps;
        checks = pkgCheckOps;
      };
    }
    // (
      if devShellPackages == null
      then {}
      else {
        devShell = pkgs.mkShell {
          packages = devShellPackages;
        };
      }
    );

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

  mkWebParts = {
    pkgs,
    src,
    pname ? deriveProjectName src,
    fmtParts ? [
      (projectFmtGlobal {})
      (projectFmtBiome pkgs {})
    ],
    fmtCheckParts ? [
      (projectFmtGlobal {})
      (projectCheckFmtBiome pkgs {})
    ],
    lintParts ? [
      (projectLintBiome pkgs {})
    ],
    lintFixParts ? [
      (projectLintFixBiome pkgs {})
    ],
    enableLint ? true,
    enableLintFix ? true,
    lintCommands ? [],
    lintFixCommands ? [],
    devShellPackages ? [
      pkgs.biome
      pkgs.nodejs
      pkgs.deno
    ],
    extraDevShellPackages ? [],
  }:
    mkPackageOpsBundle {
      inherit pkgs src pname;
      devShellPackages = devShellPackages ++ extraDevShellPackages;
      apps =
        {
          fmt = {
            parts = fmtParts;
          };
        }
        // (
          if enableLintFix
          then {
            "lint-fix" = {
              parts = lintFixParts;
              commands = lintFixCommands;
            };
          }
          else {}
        );
      checks =
        {
          fmt = {
            parts = fmtCheckParts;
          };
        }
        // (
          if enableLint
          then {
            lint = {
              parts = lintParts;
              commands = lintCommands;
            };
          }
          else {}
        );
    };

  mkProjectApp = pkgs: {
    name,
    description,
    src ? null,
    projectPath ?
      if src != null
      then deriveProjectPath src
      else throw "mkProjectApp requires projectPath or src",
    runtimeInputs ? [],
    text,
  }:
    pkgs.writeShellApplication {
      name = name;
      meta = {
        description = description;
        mainProgram = name;
      };
      runtimeInputs = [pkgs.git] ++ runtimeInputs;
      text =
        ''
          repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
          if [ -n "$repo_root" ] && [ -d "$repo_root/${projectPath}" ]; then
            cd "$repo_root/${projectPath}"
          elif [ -d "$PWD/${projectPath}" ]; then
            cd "$PWD/${projectPath}"
          elif [ -f "$PWD/flake.nix" ] || [ -f "$PWD/default.nix" ]; then
            :
          else
            printf '%s\n' "Run this from the repo root or from ${projectPath}." >&2
            exit 1
          fi
        ''
        + "\n"
        + text;
    };

  mkProjectCommandsApp = pkgs: {
    name,
    description,
    src ? null,
    projectPath ?
      if src != null
      then deriveProjectPath src
      else throw "mkProjectCommandsApp requires projectPath or src",
    parts ? [],
    runtimeInputs ? [],
    env ? {},
    repoFmtPaths ? [],
    commands,
  }: let
    resolved = resolveProjectOp pkgs {
      inherit parts env repoFmtPaths commands;
      extraInputs = runtimeInputs;
    };
  in
    mkProjectApp pkgs {
      inherit name description src projectPath;
      runtimeInputs = resolved.runtimeInputs;
      text = joinLines [resolved.envScript resolved.command];
    };

  mkProjectCheck = pkgs: {
    name,
    src,
    nativeBuildInputs ? [],
    text,
  }:
    pkgs.runCommand name {
      nativeBuildInputs = nativeBuildInputs;
    } ''
      set -euo pipefail
      cd ${src}
      ${text}
      touch "$out"
    '';

  mkProjectCommandsCheck = pkgs: {
    name,
    src,
    parts ? [],
    nativeBuildInputs ? [],
    env ? {},
    repoFmtPaths ? [],
    commands,
  }: let
    resolved = resolveProjectOp pkgs {
      inherit parts env repoFmtPaths commands;
      extraInputs = nativeBuildInputs;
      forCheck = true;
    };
  in
    mkProjectCheck pkgs {
      inherit name src;
      nativeBuildInputs = resolved.runtimeInputs;
      text =
        if resolved.writableCopy
        then ''
          tmp_tree="$TMPDIR/project-check"
          cp -r . "$tmp_tree"
          chmod -R u+w "$tmp_tree"
          cd "$tmp_tree"
          ${resolved.envScript}
          ${resolved.command}
        ''
        else joinLines [resolved.envScript resolved.command];
    };

  rustFmt = pkgs: {cargoArgs ? []}: {
    nativeBuildInputs = [pkgs.rustfmt];
    buildPhase = rustFmtCheckCommand cargoArgs;
  };

  rustFmtCommand = cargoArgs: "cargo fmt ${joinWords cargoArgs}";
  rustFmtCheckCommand = cargoArgs: joinWords (["cargo" "fmt"] ++ cargoArgs ++ ["--check"]);
  rustClippyFixCommand = cargoArgs: lintArgs: "cargo clippy ${joinWords cargoArgs} --fix --allow-dirty --allow-staged --all-targets ${joinWords lintArgs}";
  rustClippyCheckCommand = cargoArgs: lintArgs:
    joinWords (["cargo" "clippy"] ++ cargoArgs ++ lintArgs);
  rustTestCommand = cargoArgs:
    joinWords (["cargo" "test"] ++ cargoArgs);

  rustClippy = pkgs: {
    cargoArgs ? [],
    lintArgs ? ["--" "-D" "warnings"],
    nativeBuildInputs ? [],
  }: {
    nativeBuildInputs = [pkgs.clippy] ++ nativeBuildInputs;
    buildPhase = rustClippyCheckCommand cargoArgs lintArgs;
  };

  rustTest = _pkgs: {
    cargoArgs ? [],
    nativeBuildInputs ? [],
  }: {
    inherit nativeBuildInputs;
    buildPhase = rustTestCommand cargoArgs;
  };

  rustFmtApp = pkgs: {
    src ? null,
    projectPath ?
      if src != null
      then deriveProjectPath src
      else throw "rustFmtApp requires projectPath or src",
    pname ?
      if src != null
      then deriveProjectName src
      else throw "rustFmtApp requires pname or src",
    cargoArgs ? [],
  }:
    mkProjectCommandsApp pkgs {
      name = "${pname}-fmt";
      description = "Format ${pname}";
      inherit src projectPath;
      parts = [
        (projectFmtRust pkgs {inherit cargoArgs;})
      ];
      commands = ["exec ${rustFmtCommand cargoArgs} \"$@\""];
    };

  rustLintFixApp = pkgs: {
    src ? null,
    projectPath ?
      if src != null
      then deriveProjectPath src
      else throw "rustLintFixApp requires projectPath or src",
    pname ?
      if src != null
      then deriveProjectName src
      else throw "rustLintFixApp requires pname or src",
    cargoArgs ? [],
    lintArgs ? ["--" "-D" "warnings"],
  }:
    mkProjectCommandsApp pkgs {
      name = "${pname}-lint-fix";
      description = "Apply Rust lint fixes for ${pname}";
      inherit src projectPath;
      parts = [
        (projectLintFixRust pkgs {
          inherit cargoArgs lintArgs;
        })
      ];
      commands = [
        "exec ${rustClippyFixCommand cargoArgs lintArgs}"
      ];
    };

  mkRustCheckSpecs = {
    pkgs,
    clippyCargoArgs ? [],
    clippyLintArgs ? ["--" "-D" "warnings"],
    fmtCargoArgs ? [],
    testCargoArgs ? [],
    extraChecks ? {},
  }:
    {
      build = {};
      fmt = rustFmt pkgs {cargoArgs = fmtCargoArgs;};
      lint = rustClippy pkgs {
        cargoArgs = clippyCargoArgs;
        lintArgs = clippyLintArgs;
      };
      test = rustTest pkgs {cargoArgs = testCargoArgs;};
    }
    // extraChecks;

  collectNestedFlakeExtras = field: values:
    builtins.foldl'
    (acc: value:
      if builtins.isAttrs value && builtins.hasAttr field value
      then acc // (builtins.getAttr field value)
      else acc)
    {}
    values;

  wirePassthru = drv: extra: let
    extraValues = builtins.attrValues extra;
    nestedFlakeExtraPackages = collectNestedFlakeExtras "flakeExtraPackages" extraValues;
    nestedFlakeExtraApps = collectNestedFlakeExtras "flakeExtraApps" extraValues;
    nestedFlakeExtraChecks = collectNestedFlakeExtras "flakeExtraChecks" extraValues;
    nestedFlakeExtraNixosModules = collectNestedFlakeExtras "flakeExtraNixosModules" extraValues;
  in
    drv.overrideAttrs (old: let
      passthru = old.passthru or {};
    in {
      passthru =
        passthru
        // extra
        // (attrIf (nestedFlakeExtraPackages != {} || passthru ? flakeExtraPackages || extra ? flakeExtraPackages) "flakeExtraPackages" (
          (passthru.flakeExtraPackages or {})
          // nestedFlakeExtraPackages
          // (extra.flakeExtraPackages or {})
        ))
        // (attrIf (nestedFlakeExtraApps != {} || passthru ? flakeExtraApps || extra ? flakeExtraApps) "flakeExtraApps" (
          (passthru.flakeExtraApps or {})
          // nestedFlakeExtraApps
          // (extra.flakeExtraApps or {})
        ))
        // (attrIf (nestedFlakeExtraChecks != {} || passthru ? flakeExtraChecks || extra ? flakeExtraChecks) "flakeExtraChecks" (
          (passthru.flakeExtraChecks or {})
          // nestedFlakeExtraChecks
          // (extra.flakeExtraChecks or {})
        ))
        // (attrIf (nestedFlakeExtraNixosModules != {} || passthru ? flakeExtraNixosModules || extra ? flakeExtraNixosModules) "flakeExtraNixosModules" (
          (passthru.flakeExtraNixosModules or {})
          // nestedFlakeExtraNixosModules
          // (extra.flakeExtraNixosModules or {})
        ));
    });

  inferBuildSrc = build:
    if builtins.hasAttr "src" build
    then build.src
    else throw "pkg-helper: build derivation must expose `src` or the helper call must pass `src` explicitly";

  mkGoDerivation = args @ {
    build,
    src ? inferBuildSrc build,
    ...
  }:
    wirePassthru build (mkGoParts ((builtins.removeAttrs args ["build"]) // {inherit src;}));

  mkPythonDerivation = args @ {
    build,
    src ? inferBuildSrc build,
    ...
  }:
    wirePassthru build (mkPythonParts ((builtins.removeAttrs args ["build"]) // {inherit src;}));

  mkWebDerivation = args @ {
    build,
    src ? inferBuildSrc build,
    ...
  }:
    wirePassthru build (mkWebParts ((builtins.removeAttrs args ["build"]) // {inherit src;}));

  mkStaticWebDerivation = {
    pkgs,
    build,
    src ? inferBuildSrc build,
    pname ? deriveProjectName src,
    devRoot ? "site",
    devPort ? "8080",
    devBind ? "127.0.0.1",
    extraDevShellPackages ? [pkgs.python3],
    extraPassthru ? {},
    enableLint ? true,
    enableLintFix ? true,
    ...
  } @ args: let
    dev = mkProjectApp pkgs {
      name = "${pname}-dev";
      description = "Run the ${pname} static web development server";
      inherit src;
      runtimeInputs = [pkgs.python3];
      text = ''
        root="${devRoot}"
        port="${devPort}"
        bind="${devBind}"

        if [ "$#" -gt 0 ]; then
          root="$1"
          shift
        fi

        cd "$root"
        exec python -m http.server "$port" --bind "$bind" "$@"
      '';
    };
    drv =
      mkWebDerivation
      ((builtins.removeAttrs args [
          "extraDevShellPackages"
          "extraPassthru"
          "devBind"
          "devPort"
          "devRoot"
          "pname"
          "enableLint"
          "enableLintFix"
        ])
        // {
          inherit build pkgs src pname enableLint enableLintFix;
          extraDevShellPackages = extraDevShellPackages;
        });
  in
    wirePassthru drv ({dev = dev;} // extraPassthru);

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

  mkAggregateDerivation = {
    pkgs,
    src,
    pname ? deriveProjectName src,
    buildPaths ? [],
    emptyName ? "${pname}-empty",
    fmtParts ? [
      (projectFmtGlobal {})
    ],
    extraPassthru ? {},
    extraPackages ? {},
    extraApps ? {},
  }: let
    build =
      if buildPaths == []
      then
        pkgs.runCommand emptyName {} ''
          mkdir -p "$out"
        ''
      else
        pkgs.symlinkJoin {
          name = "${pname}-build";
          paths = buildPaths;
        };
    bundle = mkPackageOpsBundle {
      inherit pkgs src pname;
      apps = {
        fmt = {
          parts = fmtParts;
        };
      };
      checks = {
        fmt = {
          parts = fmtParts;
        };
      };
      devShellPackages = null;
    };
  in
    wirePassthru build ({
        build = build;
        inherit (bundle) fmt pkgOps checks;
        flakeExtraPackages = extraPackages;
        flakeExtraApps = extraApps;
      }
      // extraPassthru);

  mkRustDerivation = {
    build,
    pkgs,
    src ? inferBuildSrc build,
    pname ? deriveProjectName src,
    fmtCargoArgs ? [],
    lintFixCargoArgs ? [],
    lintFixLintArgs ? ["--" "-D" "warnings"],
    checkCargoArgs ? [],
    checkLintArgs ? ["--" "-D" "warnings"],
    testCargoArgs ? [],
    extraPassthru ? {},
  }: let
    bundle = mkPackageOpsBundle {
      inherit pkgs src pname;
      apps = {
        fmt = {
          parts = [
            (projectFmtRust pkgs {cargoArgs = fmtCargoArgs;})
          ];
          commands = ["exec ${rustFmtCommand fmtCargoArgs} \"$@\""];
        };
        "lint-fix" = {
          parts = [
            (projectLintFixRust pkgs {
              cargoArgs = lintFixCargoArgs;
              lintArgs = lintFixLintArgs;
            })
          ];
          commands = [
            "exec ${rustClippyFixCommand lintFixCargoArgs lintFixLintArgs}"
          ];
        };
      };
      checks = {
        fmt = {
          parts = [
            {
              inputs = [
                pkgs.cargo
                pkgs.rustfmt
              ];
            }
          ];
          commands = [(rustFmtCheckCommand fmtCargoArgs)];
        };
        lint = {
          parts = [
            {
              inputs = [
                pkgs.cargo
                pkgs.clippy
                pkgs.rustc
              ];
            }
          ];
          commands = [(rustClippyCheckCommand checkCargoArgs checkLintArgs)];
        };
        test = {
          parts = [
            {
              inputs = [
                pkgs.cargo
                pkgs.rustc
              ];
            }
          ];
          commands = [(rustTestCommand testCargoArgs)];
        };
      };
      devShellPackages = null;
    };
  in
    wirePassthru build ({
        inherit (bundle) fmt;
        "lint-fix" = bundle."lint-fix";
        checks = mkChecks build (mkRustCheckSpecs {
          inherit pkgs;
          clippyCargoArgs = checkCargoArgs;
          clippyLintArgs = checkLintArgs;
          fmtCargoArgs = fmtCargoArgs;
          testCargoArgs = testCargoArgs;
        });
        inherit (bundle) pkgOps;
      }
      // extraPassthru);

  mkPackageApp = pkgs: pkg: {
    type = "app";
    program = pkgs.lib.getExe pkg;
    inherit (pkg) meta;
  };

  mkNixosModuleAttrs = {
    build,
    extraModules ? {},
    resolveModule ? passthru:
      if builtins.hasAttr "nixosModule" passthru
      then
        if builtins.isAttrs passthru.nixosModule && builtins.hasAttr "__boundModuleFactory" passthru.nixosModule
        then passthru.nixosModule.__boundModuleFactory build
        else if builtins.isFunction passthru.nixosModule
        then passthru.nixosModule build
        else passthru.nixosModule
      else null,
  }: let
    passthru = build.passthru or {};
    resolvedModule = resolveModule passthru;
  in
    (attrIf (resolvedModule != null) "default" resolvedModule)
    // (attrIf (resolvedModule != null) build.pname resolvedModule)
    // (passthru.flakeExtraNixosModules or {})
    // extraModules;

  mkStdFlakeOutputs = {
    pkgs,
    build,
    checks ?
      if builtins.hasAttr "checks" build
      then build.checks
      else {},
    defaultApp ? null,
    devShell ?
      if builtins.hasAttr "devShell" build
      then build.devShell
      else null,
    extraPackages ? {},
    extraApps ? {},
    extraChecks ? {},
    extraNixosModules ? {},
  }: let
    passthru = build.passthru or {};
    passthruExtraPackages = passthru.flakeExtraPackages or {};
    passthruExtraApps = passthru.flakeExtraApps or {};
    nixosModuleAttrs = mkNixosModuleAttrs {
      inherit build;
      extraModules = extraNixosModules;
    };
    hasMainProgram = pkg:
      builtins.hasAttr "meta" pkg
      && builtins.isAttrs pkg.meta
      && builtins.hasAttr "mainProgram" pkg.meta;
    runPkg =
      if builtins.hasAttr "run" build
      then build.run
      else build;
    effectiveDefaultApp =
      if defaultApp != null
      then defaultApp
      else if hasMainProgram runPkg
      then "run"
      else if builtins.hasAttr "dev" build
      then "dev"
      else null;
    packageAttrs =
      {
        default = build;
        build = build;
        run = runPkg;
      }
      // (attrIf (builtins.hasAttr "dev" build) "dev" build.dev)
      // (attrIf (builtins.hasAttr "fmt" build) "fmt" build.fmt)
      // (attrIf (builtins.hasAttr "lint-fix" build) "lint-fix" build."lint-fix")
      // passthruExtraPackages
      // extraPackages;
    appAttrs =
      (attrIf (effectiveDefaultApp != null) "default" (
        mkPackageApp pkgs (
          if effectiveDefaultApp == "run"
          then runPkg
          else build.${effectiveDefaultApp}
        )
      ))
      // (attrIf (hasMainProgram runPkg) "run" (mkPackageApp pkgs runPkg))
      // (attrIf (builtins.hasAttr "dev" build) "dev" (mkPackageApp pkgs build.dev))
      // (attrIf (builtins.hasAttr "fmt" build) "fmt" (mkPackageApp pkgs build.fmt))
      // (attrIf (builtins.hasAttr "lint-fix" build) "lint-fix" (mkPackageApp pkgs build."lint-fix"))
      // passthruExtraApps
      // extraApps;
    devShellAttrs =
      if devShell == null
      then {}
      else {
        devShells.default = devShell;
      };
  in
    {
      packages = packageAttrs;
      apps = appAttrs;
      checks = {build = build;} // checks // extraChecks;
    }
    // (attrIf (nixosModuleAttrs != {}) "nixosModules" nixosModuleAttrs)
    // devShellAttrs;
}
