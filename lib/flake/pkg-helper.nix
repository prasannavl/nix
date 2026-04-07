let
  joinWords = parts:
    builtins.concatStringsSep " " (builtins.filter (part: part != "") parts);

  joinLines = lines:
    builtins.concatStringsSep "\n" (builtins.filter (line: line != "") lines);

  exportEnv = env:
    joinLines (builtins.attrValues (builtins.mapAttrs (name: value: "export ${name}=${builtins.toJSON value}") env));

  repoRoot = builtins.toString ../..;

  stripPrefix = prefix: str:
    let
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
    then builtins.listToAttrs [{name = name; value = value;}]
    else {};

  mergeAttrs = attrs:
    builtins.foldl' (acc: item: acc // item) {} attrs;

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

  buildFindSnippet = {
    varName,
    roots ? ["."],
    extensions,
    excludes ? [],
  }:
    let
      pruneExpr =
        if excludes == []
        then ""
        else
          "\\( "
          + builtins.concatStringsSep " -o " (map (path: "-path ${builtins.toJSON path}") excludes)
          + " \\) -prune -o ";
      nameExpr =
        builtins.concatStringsSep " -o " (map (ext: "-name ${builtins.toJSON ext}") extensions);
    in
      ''
        mapfile -d $'\0' -t ${varName} < <(
          find ${shellWords roots} ${pruneExpr}-type f \( ${nameExpr} \) -print0
        )
      '';

  buildAutoFilesSnippet = {
    varName,
    roots ? ["."],
    extensions,
    excludes ? [],
  }:
    let
      extCase =
        builtins.concatStringsSep "\n"
        (map (ext: builtins.replaceStrings ["*"] [""] ''
          ${ext})
            auto_files+=("$path")
            ;;
        '') extensions);
      excludeCase =
        if excludes == []
        then ""
        else
          builtins.concatStringsSep "\n"
          (map (path: "${path}|${path}/*) continue ;;") excludes);
      findSnippet = buildFindSnippet {
        inherit varName roots extensions excludes;
      };
    in
      ''
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
  emptyProjectParts = {
    inputs = [];
    env = {};
    repoFmtPaths = [];
    commands = [];
    writableCopy = false;
  };

  mergeProjectParts = parts:
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
    emptyProjectParts
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

  repoFmtAppCommand = {
    projectPath,
    paths,
  }:
    "treefmt --quiet --on-unmatched=debug --config-file \"$repo_root/treefmt.toml\" --tree-root \"$repo_root\" ${joinWords paths}";

  repoFmtCheckCommand = {paths}:
    "treefmt --quiet --on-unmatched=debug --fail-on-change --config-file ${../../treefmt.toml} --tree-root . ${joinWords paths}";

  repoFmtCheckEnv = env:
    {
      HOME = "$TMPDIR/home";
      XDG_CACHE_HOME = "$TMPDIR/.cache";
    }
    // env;

  projectFmtGlobal = {
    paths ? ["."],
  }: {
    repoFmtPaths = paths;
    writableCopy = true;
  };

  projectFmtBiome = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
  }: {
    inputs = [
      pkgs.biome
      pkgs.findutils
    ];
    commands = [
      (buildAutoFilesSnippet {
        varName = "biome_files";
        inherit roots excludes;
        extensions = [
          "*.js"
          "*.jsx"
          "*.mjs"
          "*.cjs"
          "*.ts"
          "*.tsx"
          "*.css"
          "*.html"
        ];
      })
      ''
        if [ "''${#biome_files[@]}" -gt 0 ]; then
          biome format --write "''${biome_files[@]}"
        fi
      ''
    ];
    writableCopy = true;
  };

  projectLintBiome = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
  }: {
    inputs = [
      pkgs.biome
      pkgs.findutils
    ];
    commands = [
      (buildAutoFilesSnippet {
        varName = "biome_lint_files";
        inherit roots excludes;
        extensions = [
          "*.js"
          "*.jsx"
          "*.mjs"
          "*.cjs"
          "*.ts"
          "*.tsx"
          "*.css"
          "*.html"
        ];
      })
      ''
        if [ "''${#biome_lint_files[@]}" -gt 0 ]; then
          biome check "''${biome_lint_files[@]}"
        fi
      ''
    ];
    writableCopy = true;
  };

  projectCheckFmtBiome = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
  }: {
    inputs = [
      pkgs.biome
      pkgs.findutils
    ];
    commands = [
      (buildAutoFilesSnippet {
        varName = "biome_fmt_check_files";
        inherit roots excludes;
        extensions = [
          "*.js"
          "*.jsx"
          "*.mjs"
          "*.cjs"
          "*.ts"
          "*.tsx"
          "*.css"
          "*.html"
        ];
      })
      ''
        if [ "''${#biome_fmt_check_files[@]}" -gt 0 ]; then
          biome check --formatter-enabled=true --linter-enabled=false "''${biome_fmt_check_files[@]}"
        fi
      ''
    ];
  };

  projectLintFixBiome = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
  }: {
    inputs = [
      pkgs.biome
      pkgs.findutils
    ];
    commands = [
      (buildAutoFilesSnippet {
        varName = "biome_fix_files";
        inherit roots excludes;
        extensions = [
          "*.js"
          "*.jsx"
          "*.mjs"
          "*.cjs"
          "*.ts"
          "*.tsx"
          "*.css"
          "*.html"
        ];
      })
      ''
        if [ "''${#biome_fix_files[@]}" -gt 0 ]; then
          biome check --write "''${biome_fix_files[@]}"
        fi
      ''
    ];
    writableCopy = true;
  };

  projectFmtRuff = pkgs: {
    paths ? ["."],
  }: {
    inputs = [pkgs.ruff];
    commands = [(ruffFmt {inherit paths;})];
  };

  projectCheckFmtRuff = pkgs: {
    paths ? ["."],
  }: {
    inputs = [pkgs.ruff];
    commands = [(ruffFmtCheck {inherit paths;})];
  };

  projectLintRuff = pkgs: {
    paths ? ["."],
  }: {
    inputs = [pkgs.ruff];
    commands = [(ruffLint {inherit paths;})];
  };

  projectLintFixRuff = pkgs: {
    paths ? ["."],
  }: {
    inputs = [pkgs.ruff];
    commands = [(ruffLintFix {inherit paths;})];
  };

  projectFmtGo = pkgs: {
    roots ? ["."],
    excludes ? (commonAutoExcludes ++ ["./vendor"]),
  }: {
    inputs = [
      pkgs.go
      pkgs.findutils
    ];
    commands = [
      (buildAutoFilesSnippet {
        varName = "go_fmt_files";
        inherit roots excludes;
        extensions = ["*.go"];
      })
      ''
        if [ "''${#go_fmt_files[@]}" -gt 0 ]; then
          gofmt -w "''${go_fmt_files[@]}"
        fi
      ''
    ];
    writableCopy = true;
  };

  projectCheckFmtGo = pkgs: {
    roots ? ["."],
    excludes ? (commonAutoExcludes ++ ["./vendor"]),
  }: {
    inputs = [
      pkgs.go
      pkgs.findutils
    ];
    commands = [
      (buildAutoFilesSnippet {
        varName = "go_check_files";
        inherit roots excludes;
        extensions = ["*.go"];
      })
      ''
        if [ "''${#go_check_files[@]}" -gt 0 ]; then
          test -z "$(gofmt -d "''${go_check_files[@]}")"
        fi
      ''
    ];
  };

  projectLintGo = pkgs: {
    paths ? ["./..."],
  }: {
    inputs = [pkgs.go];
    commands = [(goLint {inherit paths;})];
  };

  projectTestGo = pkgs: {
    paths ? ["./..."],
  }: {
    inputs = [pkgs.go];
    commands = [(goTest {inherit paths;})];
  };

  projectLintShell = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
    shell ? "bash",
    extraArgs ? ["--external-sources"],
  }: {
    inputs = [
      pkgs.findutils
      pkgs.shellcheck
    ];
    commands = [
      (buildAutoFilesSnippet {
        varName = "shell_lint_files";
        inherit roots excludes;
        extensions = ["*.sh"];
      })
      ''
        if [ "''${#shell_lint_files[@]}" -gt 0 ]; then
          shellcheck ${joinWords extraArgs} --shell=${shell} "''${shell_lint_files[@]}"
        fi
      ''
    ];
  };

  projectFmtRust = pkgs: {
    cargoArgs ? [],
  }: {
    inputs = [
      pkgs.cargo
      pkgs.rustfmt
    ];
    commands = ["cargo fmt ${joinWords cargoArgs}"];
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
    commands = [
      "cargo clippy ${joinWords cargoArgs} --fix --allow-dirty --allow-staged --all-targets ${joinWords lintArgs}"
    ];
  };

  mkConventionalProjectApp = pkgs: {
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

  mkConventionalProjectCheck = pkgs: {
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

  mkGoConventionParts = {
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
  in {
    fmt = mkConventionalProjectApp pkgs {
      kind = "fmt";
      inherit src pname;
      parts = fmtParts;
    };
    checks = {
      fmt = mkConventionalProjectCheck pkgs {
        kind = "fmt";
        inherit src pname;
        parts = fmtCheckParts;
        commands = fmtCommands;
      };
      lint = mkConventionalProjectCheck pkgs {
        kind = "lint";
        inherit src pname;
        parts = lintParts;
        env = checkEnv;
        commands = checkEnvCommands ++ lintCommands;
      };
      test = mkConventionalProjectCheck pkgs {
        kind = "test";
        inherit src pname;
        parts = testParts;
        env = checkEnv;
        commands = checkEnvCommands ++ testCommands;
      };
    };
    devShell = pkgs.mkShell {
      packages = devShellPackages;
    };
  };

  mkPythonConventionParts = {
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
  in {
    fmt = mkConventionalProjectApp pkgs {
      kind = "fmt";
      inherit src pname;
      parts = fmtParts;
    };
    "lint-fix" = mkConventionalProjectApp pkgs {
      kind = "lint-fix";
      inherit src pname;
      parts = lintFixParts;
      commands = lintFixCommands;
    };
    checks = {
      fmt = mkConventionalProjectCheck pkgs {
        kind = "fmt";
        inherit src pname;
        parts = fmtCheckParts;
        env = checkEnv;
        commands = checkEnvCommands ++ fmtCommands;
      };
      lint = mkConventionalProjectCheck pkgs {
        kind = "lint";
        inherit src pname;
        parts = lintParts;
        env = checkEnv;
        commands = checkEnvCommands ++ lintCommands;
      };
    };
    devShell = pkgs.mkShell {
      packages = devShellPackages;
    };
  };

  mkWebConventionParts = {
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
  }: {
    fmt = mkConventionalProjectApp pkgs {
      kind = "fmt";
      inherit src pname;
      parts = fmtParts;
    };
    checks =
      {
        fmt = mkConventionalProjectCheck pkgs {
          kind = "fmt";
          inherit src pname;
          parts = fmtCheckParts;
        };
      }
      // (
        if enableLint
        then {
          lint = mkConventionalProjectCheck pkgs {
            kind = "lint";
            inherit src pname;
            parts = lintParts;
            commands = lintCommands;
          };
        }
        else {}
      );
    devShell = pkgs.mkShell {
      packages = devShellPackages ++ extraDevShellPackages;
    };
  }
  // (
    if enableLintFix
    then {
      "lint-fix" = mkConventionalProjectApp pkgs {
        kind = "lint-fix";
        inherit src pname;
        parts = lintFixParts;
        commands = lintFixCommands;
      };
    }
    else {}
  );

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
  }:
    let
      mergedParts =
        mergeProjectParts (
          parts
          ++ [
            {
              inputs = runtimeInputs;
              inherit env repoFmtPaths commands;
            }
          ]
        );
    in
      mkProjectApp pkgs {
      inherit name description src projectPath;
      runtimeInputs =
        mergedParts.inputs
        ++ (
          if mergedParts.repoFmtPaths == []
          then []
          else repoFmtRuntimeInputs pkgs
        );
      text =
        joinLines (
          [(exportEnv mergedParts.env)]
          ++ (
            if mergedParts.repoFmtPaths == []
            then []
            else [
              (repoFmtAppCommand {
                inherit projectPath;
                paths = mergedParts.repoFmtPaths;
              })
            ]
          )
          ++ mergedParts.commands
        );
      };

  mkProjectCheck = pkgs: {
    name,
    src,
    nativeBuildInputs ? [],
    env ? {},
    text,
  }:
    pkgs.runCommand name {
      nativeBuildInputs = nativeBuildInputs;
    } ''
      set -euo pipefail
      cd ${src}
      ${exportEnv env}
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
  }:
    let
      mergedParts =
        mergeProjectParts (
          parts
          ++ [
            {
              inputs = nativeBuildInputs;
              inherit env repoFmtPaths commands;
            }
          ]
        );
    in
      mkProjectCheck pkgs {
      inherit name src;
      env =
        if mergedParts.repoFmtPaths == []
        then mergedParts.env
        else repoFmtCheckEnv mergedParts.env;
      nativeBuildInputs =
        mergedParts.inputs
        ++ (
          if mergedParts.repoFmtPaths == []
          then []
          else repoFmtRuntimeInputs pkgs
        );
      text =
        let
          commandBlock =
            joinLines (
              (
                if mergedParts.repoFmtPaths == []
                then []
                else [
                  ''mkdir -p "$HOME" "$XDG_CACHE_HOME"''
                  (repoFmtCheckCommand {
                    paths = mergedParts.repoFmtPaths;
                  })
                ]
              )
              ++ mergedParts.commands
            );
        in
          if mergedParts.writableCopy
          then
            ''
              tmp_tree="$TMPDIR/project-check"
              cp -r . "$tmp_tree"
              chmod -R u+w "$tmp_tree"
              cd "$tmp_tree"
              ${commandBlock}
            ''
          else commandBlock;
      };

  rustFmt = pkgs: {cargoArgs ? []}: {
    nativeBuildInputs = [pkgs.rustfmt];
    buildPhase = joinWords (["cargo" "fmt"] ++ cargoArgs ++ ["--check"]);
  };

  rustClippy = pkgs: {
    cargoArgs ? [],
    lintArgs ? ["--" "-D" "warnings"],
    nativeBuildInputs ? [],
  }: {
    nativeBuildInputs = [pkgs.clippy] ++ nativeBuildInputs;
    buildPhase = joinWords (["cargo" "clippy"] ++ cargoArgs ++ lintArgs);
  };

  rustTest = _pkgs: {
    cargoArgs ? [],
    nativeBuildInputs ? [],
  }: {
    inherit nativeBuildInputs;
    buildPhase = joinWords (["cargo" "test"] ++ cargoArgs);
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
      commands = ["exec cargo fmt ${joinWords cargoArgs} \"$@\""];
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
        "exec cargo clippy ${joinWords cargoArgs} --fix --allow-dirty --allow-staged --all-targets ${joinWords lintArgs}"
      ];
    };

  mkRustChecks = {
    build,
    pkgs,
    clippyCargoArgs ? [],
    clippyLintArgs ? ["--" "-D" "warnings"],
    fmtCargoArgs ? [],
    testCargoArgs ? [],
    extraChecks ? {},
  }: (builtins.mapAttrs (name: args:
      if name == "build"
      then build
      else mkCheckFn build ({name = name;} // args))
    ({
        build = {};
        fmt = rustFmt pkgs {cargoArgs = fmtCargoArgs;};
        lint = rustClippy pkgs {
          cargoArgs = clippyCargoArgs;
          lintArgs = clippyLintArgs;
        };
        test = rustTest pkgs {cargoArgs = testCargoArgs;};
      }
      // extraChecks));

  wirePassthru = drv: extra:
    drv.overrideAttrs (old: {
      passthru = (old.passthru or {}) // extra;
    });

  mkGoDerivation = args@{
    build,
    ...
  }:
    wirePassthru build (mkGoConventionParts (builtins.removeAttrs args ["build"]));

  mkPythonDerivation = args@{
    build,
    ...
  }:
    wirePassthru build (mkPythonConventionParts (builtins.removeAttrs args ["build"]));

  mkWebDerivation = args@{
    build,
    ...
  }:
    wirePassthru build (mkWebConventionParts (builtins.removeAttrs args ["build"]));

  mkStaticWebDerivation = {
    pkgs,
    src,
    build,
    pname ? deriveProjectName src,
    devRoot ? "site",
    devPort ? "8080",
    devBind ? "127.0.0.1",
    extraDevShellPackages ? [pkgs.python3],
    extraPassthru ? {},
    ...
  }@args:
    let
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
        ((builtins.removeAttrs args ["extraDevShellPackages" "extraPassthru" "devBind" "devPort" "devRoot" "pname"])
          // {
            inherit build pkgs src pname;
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
  }:
    let
      fmt = mkConventionalProjectApp pkgs {
        kind = "fmt";
        inherit src pname;
        parts = fmtParts;
      };
      fmtCheck = mkConventionalProjectCheck pkgs {
        kind = "fmt";
        inherit src pname;
        parts = fmtParts;
      };
      lintCheck = {
        lint = mkConventionalProjectCheck pkgs {
          kind = "lint";
          inherit src pname;
          parts = lintParts;
          commands = lintCommands;
        };
      };
      devShell =
        if devShellPackages == []
        then null
        else
          pkgs.mkShell {
            packages = devShellPackages;
          };
    in
      wirePassthru build ({
          fmt = fmt;
          checks =
            {
              fmt = fmtCheck;
            }
            // lintCheck;
        }
        // (if devShell == null then {} else {devShell = devShell;})
        // extraPassthru);

  mkRustDerivation = {
    build,
    pkgs,
    src,
    pname ? deriveProjectName src,
    fmtCargoArgs ? [],
    lintFixCargoArgs ? [],
    lintFixLintArgs ? ["--" "-D" "warnings"],
    checkCargoArgs ? [],
    checkLintArgs ? ["--" "-D" "warnings"],
    testCargoArgs ? [],
    extraPassthru ? {},
  }:
    wirePassthru build ({
      fmt = rustFmtApp pkgs {
        inherit src pname;
        cargoArgs = fmtCargoArgs;
      };
      "lint-fix" = rustLintFixApp pkgs {
        inherit src pname;
        cargoArgs = lintFixCargoArgs;
        lintArgs = lintFixLintArgs;
      };
      checks = mkRustChecks {
        inherit build pkgs;
        clippyCargoArgs = checkCargoArgs;
        clippyLintArgs = checkLintArgs;
        fmtCargoArgs = fmtCargoArgs;
        testCargoArgs = testCargoArgs;
      };
    } // extraPassthru);

  mkPackageApp = pkgs: pkg: {
    type = "app";
    program = pkgs.lib.getExe pkg;
    inherit (pkg) meta;
  };

  mkStdFlakeOutputs = {
    pkgs,
    build,
    checks ? if builtins.hasAttr "checks" build then build.checks else {},
    defaultApp ? null,
    devShell ? if builtins.hasAttr "devShell" build then build.devShell else null,
    extraPackages ? {},
    extraApps ? {},
    extraChecks ? {},
  }:
    let
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
        // extraPackages;
      appAttrs =
        mergeAttrs (
          []
          ++ (
            if effectiveDefaultApp == null
            then []
            else [
              (builtins.listToAttrs [{
                name = "default";
                value =
                  mkPackageApp pkgs
                  (if effectiveDefaultApp == "run" then runPkg else build.${effectiveDefaultApp});
              }])
            ]
          )
          ++ (if hasMainProgram runPkg then [{run = mkPackageApp pkgs runPkg;}] else [])
          ++ (if builtins.hasAttr "dev" build then [{dev = mkPackageApp pkgs build.dev;}] else [])
          ++ (if builtins.hasAttr "fmt" build then [{fmt = mkPackageApp pkgs build.fmt;}] else [])
          ++ (if builtins.hasAttr "lint-fix" build then [{"lint-fix" = mkPackageApp pkgs build."lint-fix";}] else [])
          ++ [extraApps]
        );
      devShellAttrs =
        if devShell == null
        then {}
        else {
          devShells.default = devShell;
        };
    in {
      packages = packageAttrs;
      apps = appAttrs;
      checks = ({build = build;} // checks // extraChecks);
    }
    // devShellAttrs;
}
