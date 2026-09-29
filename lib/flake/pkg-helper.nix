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

  isDerivation = value:
    builtins.isAttrs value
    && (value.type or null) == "derivation";

  shellWords = parts:
    builtins.concatStringsSep " " (map builtins.toJSON parts);

  defaultCargoPackageArgs = pkgs: projectDir: pname:
    ["--locked"]
    ++ pkgs.lib.optionals (projectDir != null) ["-p" pname];

  craneWorkspaceCargoArgs = projectDir: cargoArgs:
    if projectDir == null
    then cargoArgs
    else ["--offline"] ++ builtins.filter (arg: arg != "--locked" && arg != "--offline") cargoArgs;

  binPath = inputs:
    builtins.concatStringsSep ":" (map (input: "${input}/bin") inputs);

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

  hasPrefix = prefix: str: let
    prefixLen = builtins.stringLength prefix;
  in
    builtins.substring 0 prefixLen str == prefix;

  # Filter a repository into the smallest Cargo-usable source tree. `selectedDirs`
  # are kept in full (plus the ancestor directories needed to reach them); the
  # root manifest and lockfile are always kept, and `.cargo` configuration is
  # kept too because it is fingerprint-relevant. The output name is load-bearing:
  # crane's `mkDummySrc` derives its dummy output name from this basename, so
  # every workspace-shaped source must unpack to `/build/cargo-workspace-source`.
  mkWorkspaceSourcePath = pkgs: {
    src,
    selectedDirs,
    # `name` is invariant-critical for crane's dummy/fingerprint matching; do not
    # override it.
    name ? "cargo-workspace-source",
  }: let
    root = builtins.toString src;
    isSelectedPath = rel:
      builtins.any (dir: rel == dir || hasPrefix "${dir}/" rel) selectedDirs;
    isParentOfSelectedPath = rel:
      builtins.any (dir: hasPrefix "${rel}/" dir) selectedDirs;
    gitignorePatterns =
      [".git"]
      ++ pkgs.lib.optional (builtins.pathExists (src + "/.gitignore")) (src + "/.gitignore");
    gitignoreAllows = pkgs.nix-gitignore.gitignoreFilterPure (_: _: true) gitignorePatterns src;
  in
    builtins.path {
      path = src;
      inherit name;
      filter = path: type: let
        rel = stripPrefix "${root}/" (builtins.toString path);
      in
        gitignoreAllows path type
        && (
          rel
          == "Cargo.toml"
          || rel == "Cargo.lock"
          || rel == ".cargo"
          || hasPrefix ".cargo/" rel
          || type == "directory" && isParentOfSelectedPath rel
          || isSelectedPath rel
        );
    };

  mkCargoWorkspaceSource = pkgs: {
    src,
    projectDir,
    deps ? [],
  }: let
    filtered = mkWorkspaceSourcePath pkgs {
      inherit src;
      selectedDirs = map normalizeMemberPath ([projectDir] ++ deps);
    };
  in
    pkgs.runCommandLocal "cargo-workspace-source" {src = filtered;} ''
      forbidden="$(find "$src" \
        \( -type d -name .git -o -type d -name target -o -type d -name dist \) \
        -print -quit)"
      if [ -n "$forbidden" ]; then
        printf 'mkCargoWorkspaceSource: forbidden generated or VCS directory passed source filter: %s\n' "$forbidden" >&2
        exit 1
      fi

      mkdir -p "$out"
      cp -a "$src"/. "$out"/
    '';

  stripTrailingSlash = str:
    if str != "" && builtins.substring (builtins.stringLength str - 1) 1 str == "/"
    then builtins.substring 0 (builtins.stringLength str - 1) str
    else str;

  normalizeMemberPath = dir:
    stripTrailingSlash (
      if hasPrefix "./" dir
      then stripPrefix "./" dir
      else dir
    );

  # In-repo Cargo workspace members, read from the root manifest at evaluation
  # time. `src` must be an evaluator-visible path (never a derivation) so this
  # cannot trigger IFD. Cargo also accepts glob members (`crates/*`); this
  # reader does not expand them, so such a member falls back to the legacy
  # per-package path (correct, just not shared).
  rustWorkspaceMembers = src: let
    rootManifest = src + "/Cargo.toml";
    manifest =
      if builtins.isPath src && builtins.pathExists rootManifest
      then builtins.fromTOML (builtins.readFile rootManifest)
      else {};
    rawMembers =
      if manifest ? workspace && manifest.workspace ? members
      then manifest.workspace.members
      else [];
  in
    # Cargo allows glob members (`crates/*`); this reader does not expand them.
    # Returning no members disables workspace sharing for the whole repo (every
    # package falls back to the correct legacy per-package path) instead of
    # producing a base whose dummy source is missing those members.
    if builtins.any (member: builtins.match ".*[*?\\[].*" member != null) rawMembers
    then []
    else map normalizeMemberPath rawMembers;

  isWorkspaceMember = src: projectDir:
    builtins.elem (normalizeMemberPath projectDir) (rustWorkspaceMembers src);

  # Whole-workspace laundered source, used to derive the shared dependency
  # base's dummy source (never handed to a real member build). See
  # `mkWorkspaceSourcePath` for the filter and the load-bearing output name.
  mkRustWorkspaceSource = pkgs: src:
    mkWorkspaceSourcePath pkgs {
      inherit src;
      selectedDirs = rustWorkspaceMembers src;
    };

  # Canonical external-dependency base shared by every in-repo workspace member.
  # It takes no per-package attrs (`nativeBuildInputs`, `env`, ...) so every call
  # builds an identical derivation and Nix hash-conses a single repo-wide base.
  # `dummySrc` is passed without `src` (which `buildDepsOnly` would ignore and
  # warn about anyway); the dummy depends only on cargo manifests, the lockfile
  # and `.cargo` config, so `*.rs` edits never invalidate it.
  mkSharedRustDepsBase = pkgs: {
    source,
    cargoLockContents,
    cargoVendorDir,
  }: let
    craneLib = pkgs.craneLib;
  in
    craneLib.buildDepsOnly {
      dummySrc = craneLib.mkDummySrc {src = source;};
      pname = "abird-rust-workspace";
      version = "0.1.0";
      cargoExtraArgs = "--offline --workspace";
      inherit cargoLockContents cargoVendorDir;
    };

  # Join several members' artifact layers into one self-contained archive. Crane
  # chains a single `.prev` parent, so a member with two or more in-repo
  # dependencies needs an explicit join. This materialises the union as one full
  # archive (simple and correct); it is only needed when fan-in occurs.
  mkCargoArtifactsJoin = pkgs: {
    name,
    deps,
  }: let
    craneLib = pkgs.craneLib;
  in
    craneLib.mkCargoDerivation {
      pname = "${name}-cargo-artifacts";
      version = "0.1.0";
      src = null;
      dontUnpack = true;
      cargoArtifacts = builtins.head deps;
      cargoVendorDir = null;
      doCheck = false;
      doInstallCargoArtifacts = true;
      doCompressAndInstallFullArchive = "1";
      buildPhaseCargoCommand = "";
      checkPhaseCargoCommand = "";
      preBuild = joinLines (map (dep: "inheritCargoArtifacts ${dep}") (builtins.tail deps));
    };

  mkCraneCargoLockAttrs = {
    src,
    cargoLock ? null,
  }:
    if cargoLock != null
    then
      if builtins.isAttrs cargoLock && builtins.hasAttr "lockFileContents" cargoLock
      then {cargoLockContents = cargoLock.lockFileContents;}
      else {inherit cargoLock;}
    # Only inspect evaluator-visible sources. Probing a fetched derivation here
    # would realise it during evaluation (IFD); Crane can consume its lockfile
    # from the source tree inside the build instead.
    else if builtins.isPath src && builtins.pathExists (src + "/Cargo.lock")
    then {cargoLockContents = builtins.readFile (src + "/Cargo.lock");}
    else {};

  cargoWorkspacePrePatch = {
    projectDir,
    deps ? [],
  }: let
    selectedDirs = map normalizeMemberPath ([projectDir] ++ deps);
    selectedMembersText =
      builtins.concatStringsSep "\n"
      (map (dir: "  ${builtins.toJSON dir},") selectedDirs);
  in ''
    awk '
      /^members = \[/ {
        print "members = ["
        print ${builtins.toJSON selectedMembersText}
        in_members = 1
        next
      }
      in_members && /^\]/ {
        print
        in_members = 0
        next
      }
      ! in_members { print }
    ' Cargo.toml > Cargo.toml.tmp
    mv Cargo.toml.tmp Cargo.toml
  '';

  composeCargoWorkspacePrePatch = {
    projectDir,
    deps ? [],
    prePatch ? "",
  }:
    joinLines [
      (
        if projectDir == null
        then ""
        else cargoWorkspacePrePatch {inherit projectDir deps;}
      )
      prePatch
    ];

  shellArrayRef = varName:
    builtins.concatStringsSep "" [
      "\"\${"
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
    build.overrideAttrs (old: let
      extraNativeBuildInputs = args.nativeBuildInputs or [];
    in {
      pname = "${old.pname}-${args.name}";
      nativeBuildInputs =
        (builtins.filter
          (input: !(builtins.elem input (args.removeNativeBuildInputs or [])))
          (old.nativeBuildInputs or []))
        ++ extraNativeBuildInputs;
      nativeCheckInputs =
        if builtins.hasAttr "nativeCheckInputs" args
        then args.nativeCheckInputs
        else if builtins.hasAttr "removeNativeBuildInputs" args
        then []
        else old.nativeCheckInputs or [];
      buildPhase = joinLines [
        (
          if extraNativeBuildInputs == []
          then ""
          else "export PATH=${builtins.toJSON (binPath extraNativeBuildInputs)}:$PATH"
        )
        (args.preBuildPhase or "")
        (
          if old ? buildAndTestSubdir && old.buildAndTestSubdir != null
          then "cd ${builtins.toJSON old.buildAndTestSubdir}"
          else ""
        )
        args.buildPhase
      ];
      installPhase = "touch $out";
      doCheck = false;
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
    projectPath ? deriveProjectPath src,
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
      projectPath = projectPath;
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
    projectPath ? deriveProjectPath src,
    parts ? [],
    runtimeInputs ? [],
    env ? {},
    repoFmtPaths ? [],
    commands ? [],
    ...
  }:
    mkProjectAppOp pkgs {
      inherit src projectPath parts runtimeInputs env repoFmtPaths commands;
    };

  mkStdCheckOp = pkgs: {
    src,
    projectPath ? deriveProjectPath src,
    parts ? [],
    nativeBuildInputs ? [],
    env ? {},
    repoFmtPaths ? [],
    commands ? [],
    ...
  }:
    mkProjectCheckOp pkgs {
      inherit src projectPath parts nativeBuildInputs env repoFmtPaths commands;
    };

  stripPkgOp = spec:
    if spec == null
    then null
    else builtins.removeAttrs spec ["runtimeInputs"];

  isSupportedOnCurrentSystem = pkgs: input: let
    resolved = builtins.tryEval input;
  in
    if !resolved.success
    then false
    else if !builtins.isAttrs resolved.value
    then true
    else if !(builtins.hasAttr "meta" resolved.value && builtins.hasAttr "platforms" resolved.value.meta)
    then true
    else pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform resolved.value;

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
    builtins.filter (item: item != null) (
      appInputs ++ checkInputs
    );

  pkgOpsManifest = pkgs: packageSet: {
    packages = builtins.filter (entry: entry != null) (
      map (
        name: let
          packageEval = builtins.tryEval (packageSet.${name} or null);
          drv = packageEval.value;
          pkgOpsEval = builtins.tryEval (
            if
              packageEval.success
              && isSupportedOnCurrentSystem pkgs drv
              && builtins.isAttrs drv
              && builtins.hasAttr "passthru" drv
            then (drv.passthru.pkgOps or null)
            else null
          );
          pkgOps = pkgOpsEval.value;
        in
          if
            !packageEval.success
            || !pkgOpsEval.success
            || pkgOps == null
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

  pkgOpsRuntimeInputs = pkgs: packageSet:
    builtins.concatLists (
      map (
        name: let
          packageEval = builtins.tryEval (packageSet.${name} or null);
          drv = packageEval.value;
          pkgOpsEval = builtins.tryEval (
            if
              packageEval.success
              && isSupportedOnCurrentSystem pkgs drv
              && builtins.isAttrs drv
              && builtins.hasAttr "passthru" drv
            then (drv.passthru.pkgOps or null)
            else null
          );
          pkgOps = pkgOpsEval.value;
        in
          if
            !packageEval.success
            || !pkgOpsEval.success
            || pkgOps == null
          then []
          else collectPkgOpInputs pkgOps
      ) (builtins.attrNames packageSet)
    );

  mkPackageOpsBundle = {
    pkgs,
    src,
    pname ? deriveProjectName src,
    projectPath ? deriveProjectPath src,
    apps ? {},
    checks ? {},
    devShellPackages ? null,
  }: let
    path = projectPath;
    appDrvs = builtins.mapAttrs (kind: spec:
      mkStdApp pkgs ({
          inherit kind src pname projectPath;
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
          inherit kind src projectPath;
        }
        // spec))
    apps;
    pkgCheckOps = builtins.mapAttrs (kind: spec:
      mkStdCheckOp pkgs ({
          inherit kind src projectPath;
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

  rustFmt = pkgs: {
    cargoArgs ? [],
    nativeBuildInputs ? [],
  }: {
    nativeBuildInputs = [pkgs.rustfmt] ++ nativeBuildInputs;
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
    fmtNativeBuildInputs ? [],
    lintNativeBuildInputs ? [],
    nativeCheckInputs ? [],
    preBuildPhase ? "",
    testCargoArgs ? [],
    extraChecks ? {},
  }:
    {
      build = {};
      fmt =
        rustFmt pkgs {
          cargoArgs = fmtCargoArgs;
          nativeBuildInputs = fmtNativeBuildInputs;
        }
        // {removeNativeBuildInputs = nativeCheckInputs;};
      lint =
        rustClippy pkgs {
          cargoArgs = clippyCargoArgs;
          lintArgs = clippyLintArgs;
          nativeBuildInputs = lintNativeBuildInputs;
        }
        // {removeNativeBuildInputs = nativeCheckInputs;}
        // (attrIf (preBuildPhase != "") "preBuildPhase" preBuildPhase);
      test =
        rustTest pkgs {
          cargoArgs = testCargoArgs;
          nativeBuildInputs = nativeCheckInputs;
        }
        // (attrIf (preBuildPhase != "") "preBuildPhase" preBuildPhase);
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

  mkTrunkProject = {
    pkgs,
    src ?
      if projectDir == null
      then throw "pkg-helper.mkTrunkProject: pass `src` when `projectDir` is null"
      else ../..,
    pname ? deriveProjectName src,
    version ? "0.1.0",
    cargoLock ? null,
    wasmBindgenCli ? pkgs.wasm-bindgen-cli_0_2_114,
    wasmBindgenVersion ? "0.2.114",
    trunk ? pkgs.trunk,
    trunkBootstrapTarget ? pname,
    devPort ? "4001",
    installSubdir ? pname,
    deps ? [],
    projectPath ?
      if projectDir == null
      then deriveProjectPath src
      else projectDir,
    projectDir ? null,
    description ? "${pname} web app",
    meta ? {description = description;},
    extraNativeBuildInputs ? [],
    extraDevRuntimeInputs ? [],
    extraDevShellPackages ? [pkgs.rust-analyzer],
    nativeCheckInputs ? [],
    fmtNativeBuildInputs ? [],
    lintNativeBuildInputs ? [],
    checkEnv ? {},
    buildAttrs ? {},
    extraPassthru ? {},
    fmtCargoArgs ? [],
    lintFixCargoArgs ? ["--locked"],
    checkCargoArgs ? ["--locked"],
    testCargoArgs ? ["--locked"],
    cargoBuildArgs ? null,
  }: let
    buildAttrsNoPrePatch = builtins.removeAttrs buildAttrs ["prePatch"];
    buildPrePatch = composeCargoWorkspacePrePatch {
      inherit projectDir deps;
      prePatch = buildAttrs.prePatch or "";
    };
    shellInit = ''
      unset NO_COLOR CLICOLOR CLICOLOR_FORCE
      export CARGO_BUILD_TARGET=wasm32-unknown-unknown
      export TRUNK_TOOLS_WASM_BINDGEN=${wasmBindgenVersion}
      export TRUNK_WASM_BOOTSTRAP_HOOK=${./trunk/write-wasm-bootstrap.sh}
      export TRUNK_WASM_BOOTSTRAP_TARGET=${trunkBootstrapTarget}
    '';
    buildToolchain =
      [
        pkgs.binaryen
        pkgs.llvmPackages.lld
        trunk
        wasmBindgenCli
      ]
      ++ extraNativeBuildInputs;
    devRuntimeInputs =
      buildToolchain
      ++ [
        pkgs.cargo
        pkgs.git
        pkgs.rustc
      ]
      ++ extraDevRuntimeInputs;
    devShell = pkgs.mkShell {
      packages = devRuntimeInputs ++ extraDevShellPackages;
      shellHook = shellInit;
    };
    dev = mkProjectApp pkgs {
      name = "${pname}-dev";
      description = "Run the ${pname} Trunk development server";
      src = src;
      inherit projectPath;
      runtimeInputs = devRuntimeInputs;
      text = ''
        ${shellInit}

        default_port=${devPort}

        if [ "$#" -eq 0 ]; then
          exec trunk serve --port "$default_port"
        fi

        exec trunk serve "$@"
      '';
    };
    build = let
      buildSrc =
        if projectDir == null
        then src
        else
          mkCargoWorkspaceSource pkgs {
            inherit src projectDir deps;
          };
      resolvedCargoLock =
        if cargoLock != null
        then cargoLock
        else {lockFileContents = builtins.readFile (src + "/Cargo.lock");};
      resolvedCraneCargoLockAttrs =
        if cargoLock == null
        then {cargoLockContents = builtins.readFile (src + "/Cargo.lock");}
        else if builtins.isAttrs cargoLock && builtins.hasAttr "lockFileContents" cargoLock
        then {cargoLockContents = cargoLock.lockFileContents;}
        else {cargoLock = cargoLock;};
      resolvedBuildCargoArgs =
        if cargoBuildArgs == null
        then defaultCargoPackageArgs pkgs projectDir pname
        else cargoBuildArgs;
      cargoExtraArgs = shellWords (craneWorkspaceCargoArgs projectDir resolvedBuildCargoArgs);
      commonAttrs = {
        inherit pname version meta;
        src = buildSrc;
        prePatch = buildPrePatch;

        nativeBuildInputs = buildToolchain;
        doCheck = false;
      };

      cargoBuildAttrs =
        commonAttrs
        // buildAttrsNoPrePatch
        // {
          CARGO_BUILD_TARGET = "wasm32-unknown-unknown";
        };

      trunkBuildAttrs =
        commonAttrs
        // buildAttrsNoPrePatch
        // {
          doNotPostBuildInstallCargoBinaries = true;

          buildPhase = ''
            runHook preBuild

            ${shellInit}
            ${
              if projectDir == null
              then ""
              else ''cd ${builtins.toJSON projectDir}''
            }
            export HOME="$TMPDIR/home"
            export XDG_CACHE_HOME="$TMPDIR/.cache"
            export TRUNK_OFFLINE=true
            install -d "$HOME" "$XDG_CACHE_HOME"

            trunk build --release --dist "$TMPDIR/dist"

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            install -d "$out/share/${installSubdir}"
            cp -r "$TMPDIR/dist"/. "$out/share/${installSubdir}/"

            runHook postInstall
          '';
        };

      craneLib = pkgs.craneLib or null;
      craneCargoVendorDir =
        if craneLib == null
        then null
        else craneLib.vendorCargoDeps resolvedCraneCargoLockAttrs;
      craneAttrs = value:
        value
        // resolvedCraneCargoLockAttrs
        // {cargoVendorDir = craneCargoVendorDir;};
      craneDepsAttrs = let
        baseAttrs = builtins.removeAttrs (craneAttrs cargoBuildAttrs) ["src"];
        perProjectSourcePath =
          if projectDir == null || !(builtins.isPath src)
          then null
          else
            mkWorkspaceSourcePath pkgs {
              inherit src;
              selectedDirs = map normalizeMemberPath ([projectDir] ++ deps);
            };
      in
        if perProjectSourcePath != null
        then baseAttrs // {dummySrc = craneLib.mkDummySrc {src = perProjectSourcePath;};}
        else if !(isDerivation buildSrc)
        then baseAttrs // {dummySrc = craneLib.mkDummySrc {src = buildSrc;};}
        else baseAttrs // {dummySrc = buildSrc;};
    in
      if craneLib != null && !(builtins.hasAttr "cargoDeps" buildAttrs)
      then
        craneLib.buildPackage (
          craneAttrs trunkBuildAttrs
          // {
            cargoExtraArgs = cargoExtraArgs;
            cargoArtifacts = craneLib.buildDepsOnly (
              craneDepsAttrs
              // {
                cargoExtraArgs = cargoExtraArgs;
              }
            );
          }
        )
      else
        pkgs.rustPlatform.buildRustPackage (
          trunkBuildAttrs
          // {
            cargoLock = resolvedCargoLock;
          }
          // (attrIf (projectDir != null) "buildAndTestSubdir" projectDir)
        );
    drv = mkRustDerivation {
      projectDir = projectPath;
      inherit pkgs build src pname fmtCargoArgs lintFixCargoArgs checkCargoArgs testCargoArgs cargoBuildArgs;
      inherit nativeCheckInputs fmtNativeBuildInputs lintNativeBuildInputs checkEnv;
    };
    baseDrv = wirePassthru drv {
      dev = dev;
      devShell = devShell;
    };
    resolvedExtraPassthru =
      if builtins.isFunction extraPassthru
      then extraPassthru baseDrv
      else extraPassthru;
  in
    wirePassthru baseDrv resolvedExtraPassthru;

  mkCraneRustPackage = {
    attrs,
    cargoExtraArgs ? "--locked",
    craneLib ? null,
    depsOnlyAttrs ? {},
    finalAttrs ? {},
    rustPlatform,
    fallbackAttrs ? finalAttrs,
  }: let
    sourceIsDerivation =
      builtins.hasAttr "src" attrs
      && isDerivation attrs.src;
    needsFetchedCargoDeps =
      sourceIsDerivation
      && (attrs.cargoHash or null) != null
      && !(builtins.hasAttr "cargoDeps" attrs)
      && !(builtins.hasAttr "cargoVendorDir" attrs);
    cargoVendorSourceAttrs =
      builtins.intersectAttrs {
        cargoRoot = null;
        name = null;
        pname = null;
        postUnpack = null;
        preUnpack = null;
        sourceRoot = null;
        src = null;
        srcs = null;
        unpackPhase = null;
        version = null;
      }
      attrs;
    resolvedCargoVendorAttrs =
      if needsFetchedCargoDeps
      then let
        cargoDeps = rustPlatform.fetchCargoVendor (
          cargoVendorSourceAttrs
          // {
            hash = attrs.cargoHash;
            patches = attrs.cargoPatches or [];
          }
        );
      in {
        # fetchCargoVendor carries its own Cargo source configuration (including
        # Git dependencies). Let cargoSetupHook install that configuration and
        # tell Crane not to synthesize a second vendor tree from the fetched
        # source during evaluation.
        cargoDeps = cargoDeps;
        cargoVendorDir = null;
      }
      else {};
    resolvedCraneCargoLockAttrs =
      if builtins.hasAttr "src" attrs
      then
        mkCraneCargoLockAttrs {
          inherit (attrs) src;
          cargoLock = attrs.cargoLock or null;
        }
      else {};
    attrsNoCargoLock = builtins.removeAttrs attrs ["cargoLock"];
    depsOnlyBaseAttrs =
      # A fetched (`derivation`) `attrs.src` cannot be dummied without IFD, so it
      # is used as `dummySrc` verbatim (the no-IFD contract is kept; cache
      # correctness is traded for it). Path sources fall through and are dummied
      # by crane.
      if sourceIsDerivation
      then
        builtins.removeAttrs attrsNoCargoLock ["src"]
        // {dummySrc = attrs.src;}
      else attrsNoCargoLock;
    depsOnlyMergedAttrs =
      depsOnlyBaseAttrs
      // resolvedCargoVendorAttrs
      // resolvedCraneCargoLockAttrs
      // depsOnlyAttrs;
    finalMergedAttrs =
      attrsNoCargoLock
      // resolvedCargoVendorAttrs
      // resolvedCraneCargoLockAttrs
      // finalAttrs;
    withCargoSetupHook = mergedAttrs:
      mergedAttrs
      // (
        if needsFetchedCargoDeps
        then {nativeBuildInputs = (mergedAttrs.nativeBuildInputs or []) ++ [rustPlatform.cargoSetupHook];}
        else {}
      );
    cargoArtifacts =
      if craneLib == null
      then null
      else
        craneLib.buildDepsOnly (
          withCargoSetupHook depsOnlyMergedAttrs
          // {
            cargoExtraArgs = cargoExtraArgs;
          }
        );
  in
    if craneLib == null
    then rustPlatform.buildRustPackage (attrs // fallbackAttrs)
    else
      craneLib.buildPackage (
        withCargoSetupHook finalMergedAttrs
        // {
          inherit cargoArtifacts;
          cargoExtraArgs = cargoExtraArgs;
        }
      );

  mkCargoWorkspacePackage = {
    pkgs,
    build ? null,
    src,
    pname ? deriveProjectName src,
    version ? "0.1.0",
    projectDir ? null,
    cargoPackage ? null,
    cargoBuildPackages ? [],
    cargoLock ? null,
    meta ? {},
    nativeCheckInputs ? [],
    fmtNativeBuildInputs ? [],
    lintNativeBuildInputs ? [],
    checkEnv ? {},
    buildAttrs ? {},
    prePatch ? "",
    fmtCargoArgs ? [],
    lintFixCargoArgs ? null,
    lintFixLintArgs ? ["--" "-D" "warnings"],
    cargoBuildArgs ? null,
    checkCargoArgs ? null,
    checkLintArgs ? ["--" "-D" "warnings"],
    testCargoArgs ? null,
    enableDevShell ? false,
    devShellPackages ? [
      pkgs.cargo
      pkgs.rust-analyzer
      pkgs.rustc
    ],
    extraDevShellPackages ? [],
    extraPassthru ? {},
    ...
  } @ args: let
    _ =
      if projectDir != null
      then throw "pkg-helper.mkCargoWorkspacePackage builds isolated workspaces; omit `projectDir` and pass package-local `src`"
      else null;
    cargoArgsForPackages = packageNames:
      ["--locked"]
      ++ builtins.concatLists (map (packageName: ["-p" packageName]) packageNames);
    resolvedCargoBuildPackages =
      if cargoBuildPackages == []
      then pkgs.lib.optional (cargoPackage != null) cargoPackage
      else pkgs.lib.unique cargoBuildPackages;
    defaultScopedCargoArgs = cargoArgsForPackages (pkgs.lib.optional (cargoPackage != null) cargoPackage);
    defaultBuildCargoArgs = cargoArgsForPackages resolvedCargoBuildPackages;
    resolvedBuildCargoArgs =
      if cargoBuildArgs == null
      then defaultBuildCargoArgs
      else cargoBuildArgs;
    resolvedCheckCargoArgs =
      if checkCargoArgs == null
      then defaultScopedCargoArgs
      else checkCargoArgs;
    resolvedLintFixCargoArgs =
      if lintFixCargoArgs == null
      then defaultScopedCargoArgs
      else lintFixCargoArgs;
    resolvedTestCargoArgs =
      if testCargoArgs == null
      then defaultScopedCargoArgs
      else testCargoArgs;
    resolvedCargoLock =
      if cargoLock != null
      then cargoLock
      else {lockFileContents = builtins.readFile (src + "/Cargo.lock");};
    buildArgs = builtins.removeAttrs args [
      "pkgs"
      "build"
      "src"
      "pname"
      "version"
      "projectDir"
      "cargoPackage"
      "cargoBuildPackages"
      "cargoLock"
      "meta"
      "nativeCheckInputs"
      "fmtNativeBuildInputs"
      "lintNativeBuildInputs"
      "checkEnv"
      "buildAttrs"
      "prePatch"
      "fmtCargoArgs"
      "lintFixCargoArgs"
      "lintFixLintArgs"
      "cargoBuildArgs"
      "checkCargoArgs"
      "checkLintArgs"
      "testCargoArgs"
      "enableDevShell"
      "devShellPackages"
      "extraDevShellPackages"
      "extraPassthru"
    ];
    resolvedNativeCheckInputs =
      nativeCheckInputs
      ++ (buildAttrs.nativeCheckInputs or []);
    buildPrePatch = joinLines [
      prePatch
      (buildAttrs.prePatch or "")
    ];
    buildAttrsNoPrePatch = builtins.removeAttrs buildAttrs ["prePatch" "nativeCheckInputs"];
    commonBuildAttrs =
      {
        inherit pname version meta src;
        prePatch = buildPrePatch;
        nativeCheckInputs = resolvedNativeCheckInputs;
        cargoBuildFlags = buildAttrs.cargoBuildFlags or resolvedBuildCargoArgs;
        cargoTestFlags = buildAttrs.cargoTestFlags or resolvedTestCargoArgs;
      }
      // buildArgs
      // buildAttrsNoPrePatch;
    resolvedBuild =
      if build != null
      then build
      else
        pkgs.rustPlatform.buildRustPackage (
          commonBuildAttrs
          // {
            cargoLock = resolvedCargoLock;
          }
        );
  in
    mkRustDerivation (
      (builtins.removeAttrs args [
        "build"
        "cargoBuildArgs"
        "cargoBuildPackages"
        "cargoPackage"
        "checkCargoArgs"
        "fmtCargoArgs"
        "lintFixCargoArgs"
        "testCargoArgs"
      ])
      // {
        build = resolvedBuild;
        cargoBuildArgs = resolvedBuildCargoArgs;
        checkCargoArgs = resolvedCheckCargoArgs;
        fmtCargoArgs = fmtCargoArgs;
        lintFixCargoArgs = resolvedLintFixCargoArgs;
        testCargoArgs = resolvedTestCargoArgs;
      }
    );

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
    pkgs,
    build ? null,
    src ?
      if build == null
      then
        if projectDir == null
        then throw "pkg-helper.mkRustDerivation: pass `src` when `projectDir` is null"
        else ../..
      else inferBuildSrc build,
    pname ? deriveProjectName src,
    version ? "0.1.0",
    projectDir ? null,
    projectPath ?
      if projectDir == null
      then deriveProjectPath src
      else projectDir,
    deps ? [],
    # `useWorkspaceDeps` opts a package into the shared dependency base; it
    # defaults on for in-repo workspace members. `internalDeps` lists the package
    # derivations of in-repo dependencies whose compiled artifacts this package
    # inherits. Each entry must be a workspace member exposing
    # `passthru.memberLayer` and `passthru.projectDir`; its member directory is
    # auto-unioned into the source (transitive members still belong in `deps`).
    useWorkspaceDeps ? projectDir != null,
    internalDeps ? [],
    cargoLock ? null,
    meta ? {},
    nativeCheckInputs ? [],
    fmtNativeBuildInputs ? [],
    lintNativeBuildInputs ? [],
    checkEnv ? {},
    buildAttrs ? {},
    prePatch ? "",
    fmtCargoArgs ? [],
    lintFixCargoArgs ? ["--locked" "-p" pname],
    lintFixLintArgs ? ["--" "-D" "warnings"],
    cargoBuildArgs ? null,
    checkCargoArgs ? null,
    checkLintArgs ? ["--" "-D" "warnings"],
    testCargoArgs ? null,
    enableDevShell ? false,
    devShellPackages ? [
      pkgs.cargo
      pkgs.rust-analyzer
      pkgs.rustc
    ],
    extraDevShellPackages ? [],
    extraPassthru ? {},
    ...
  } @ args: let
    resolvedFmtCargoArgs =
      if builtins.hasAttr "fmtCargoArgs" args
      then fmtCargoArgs
      else ["-p" pname];
    defaultPackageCargoArgs = defaultCargoPackageArgs pkgs projectDir pname;
    resolvedBuildCargoArgs =
      if cargoBuildArgs == null
      then defaultPackageCargoArgs
      else cargoBuildArgs;
    resolvedCheckCargoArgs =
      if checkCargoArgs == null
      then defaultPackageCargoArgs
      else checkCargoArgs;
    resolvedTestCargoArgs =
      if testCargoArgs == null
      then defaultPackageCargoArgs
      else testCargoArgs;
    resolvedCraneWorkspaceCargoArgs = craneWorkspaceCargoArgs projectDir;
    sourcePath =
      if projectDir == null
      then null
      else src + "/${projectPath}/default.nix";
    buildArgs = builtins.removeAttrs args [
      "pkgs"
      "build"
      "src"
      "pname"
      "version"
      "projectDir"
      "projectPath"
      "deps"
      "useWorkspaceDeps"
      "internalDeps"
      "cargoLock"
      "meta"
      "nativeCheckInputs"
      "fmtNativeBuildInputs"
      "lintNativeBuildInputs"
      "checkEnv"
      "buildAttrs"
      "prePatch"
      "fmtCargoArgs"
      "lintFixCargoArgs"
      "lintFixLintArgs"
      "cargoBuildArgs"
      "checkCargoArgs"
      "checkLintArgs"
      "testCargoArgs"
      "enableDevShell"
      "devShellPackages"
      "extraDevShellPackages"
      "extraPassthru"
    ];
    resolvedNativeCheckInputs =
      nativeCheckInputs
      ++ (buildAttrs.nativeCheckInputs or []);
    resolvedFmtNativeBuildInputs = fmtNativeBuildInputs;
    resolvedLintNativeBuildInputs = lintNativeBuildInputs;
    rustCheckPreBuildPhase = joinLines [
      (exportEnv checkEnv)
      (
        if projectDir == null
        then ""
        else "cargo generate-lockfile --offline"
      )
    ];
    rustBuildPlan =
      if build != null
      then null
      else let
        craneLib = pkgs.craneLib or null;
        # In-repo workspace members share one dummy-sourced dependency base (see
        # `sharedDepsBase` below). Member layers keep their own per-member source
        # so that editing one member's `*.rs` only invalidates that member and
        # its dependents. Every other shape (no `projectDir`, no crane,
        # non-member) keeps the legacy per-package behavior.
        workspaceMode =
          useWorkspaceDeps
          && craneLib != null
          && projectDir != null
          && builtins.isPath src
          && isWorkspaceMember src projectDir;
        # Whole-workspace laundered source, used only to derive the shared
        # dependency base's dummy source (never handed to a real member build).
        workspaceSource =
          if workspaceMode
          then mkRustWorkspaceSource pkgs src
          else null;
        # In-repo dependency member directories must be part of this package's
        # source tree. Derive them from each `internalDeps` package's
        # pass-through so `deps` never has to be hand-synced with `internalDeps`.
        internalDepDirs = map (dep:
          if dep == null || !(isDerivation dep)
          then throw "pkg-helper.mkRustDerivation: internalDeps entries must be package derivations"
          else let
            dir = (dep.passthru or {}).projectDir or null;
          in
            if dir == null
            then throw "pkg-helper.mkRustDerivation: each `internalDeps` entry must be a workspace member exposing `passthru.projectDir`"
            else dir)
        internalDeps;
        resolvedDeps = pkgs.lib.unique (deps ++ internalDepDirs);
        buildSrc =
          if projectDir == null
          then src
          else
            mkCargoWorkspaceSource pkgs {
              inherit src projectDir;
              deps = resolvedDeps;
            };
        resolvedCargoLock =
          if cargoLock != null
          then cargoLock
          else {lockFileContents = builtins.readFile (src + "/Cargo.lock");};
        resolvedCraneCargoLockAttrs =
          if cargoLock == null
          then {cargoLockContents = builtins.readFile (src + "/Cargo.lock");}
          else if builtins.isAttrs cargoLock && builtins.hasAttr "lockFileContents" cargoLock
          then {cargoLockContents = cargoLock.lockFileContents;}
          else {cargoLock = cargoLock;};
        # Rewrite the root member list down to this package's own source set so
        # the per-member tree is self-contained and `-p <member>` resolves it.
        buildPrePatch = composeCargoWorkspacePrePatch {
          inherit projectDir;
          deps = resolvedDeps;
          prePatch = joinLines [
            prePatch
            (buildAttrs.prePatch or "")
          ];
        };
        buildAttrsNoPrePatch = builtins.removeAttrs buildAttrs ["prePatch" "nativeCheckInputs"];
        resolvedCraneBuildCargoArgs = resolvedCraneWorkspaceCargoArgs resolvedBuildCargoArgs;
        resolvedCraneCheckCargoArgs = resolvedCraneWorkspaceCargoArgs resolvedCheckCargoArgs;
        resolvedCraneTestCargoArgs = resolvedCraneWorkspaceCargoArgs resolvedTestCargoArgs;
        commonAttrs =
          {
            inherit pname version meta;
            src = buildSrc;
            prePatch = buildPrePatch;
            nativeCheckInputs = resolvedNativeCheckInputs;
          }
          // buildArgs
          // buildAttrsNoPrePatch;
        craneCargoVendorDir =
          if craneLib == null
          then null
          else craneLib.vendorCargoDeps resolvedCraneCargoLockAttrs;
        craneCommonAttrs =
          commonAttrs
          // resolvedCraneCargoLockAttrs
          // {cargoVendorDir = craneCargoVendorDir;};
        # Legacy (non-workspace) dependency base. `mkCargoWorkspaceSource`
        # returns a derivation, so dummy it from an evaluator-visible path source
        # (`.rs`-invariant, no IFD) rather than using the real source as
        # `dummySrc`. The real-derivation fallback keeps IFD-freedom where no
        # path is available.
        perProjectSourcePath =
          if projectDir == null || !(builtins.isPath src)
          then null
          else
            mkWorkspaceSourcePath pkgs {
              inherit src;
              selectedDirs = map normalizeMemberPath ([projectDir] ++ resolvedDeps);
            };
        craneDepsAttrs =
          if !(isDerivation buildSrc)
          then craneCommonAttrs
          else
            builtins.removeAttrs craneCommonAttrs ["src"]
            // (
              if perProjectSourcePath != null
              then {dummySrc = craneLib.mkDummySrc {src = perProjectSourcePath;};}
              else {dummySrc = buildSrc;}
            );
        # Legacy per-package dependency base; unused once `workspaceMode` is on.
        packageCargoArtifacts =
          if craneLib == null
          then null
          else
            craneLib.buildDepsOnly (
              craneDepsAttrs
              // {
                cargoExtraArgs = shellWords resolvedCraneBuildCargoArgs;
              }
            );
        # One dummy-sourced whole-workspace build, so every external and dev
        # dependency compiles once repo-wide regardless of `*.rs` edits. (Until
        # the union base and `-p` member builds request identical feature sets,
        # a few shared crates may still recompile per member; see W10.)
        sharedDepsBase =
          if !workspaceMode
          then null
          else
            mkSharedRustDepsBase pkgs {
              source = workspaceSource;
              cargoLockContents =
                resolvedCraneCargoLockAttrs.cargoLockContents
                or (
                  if builtins.isPath cargoLock
                  then builtins.readFile cargoLock
                  else throw "pkg-helper.mkRustDerivation: workspace mode needs evaluator-visible lock contents; pass `cargoLock = { lockFileContents = ...; }` or a path"
                );
              cargoVendorDir = craneCargoVendorDir;
            };
        # Artifacts this member's build inherits: the shared base prefix, or the
        # artifacts-only layer(s) of in-repo dependencies. A dependency may itself
        # be outside workspace mode (its own `useWorkspaceDeps = false` rollback)
        # and then has no `memberLayer`; drop it from the artifact chain and let
        # this layer compile it from source instead of failing.
        internalDepsGuard =
          if internalDeps == []
          then null
          else if craneLib == null
          then throw "pkg-helper.mkRustDerivation: internalDeps requires craneLib"
          else if projectDir == null || !(builtins.isPath src)
          then throw "pkg-helper.mkRustDerivation: internalDeps requires a member `projectDir` and a path `src`"
          else null;
        memberLayerOf = dep: (dep.passthru or {}).memberLayer or null;
        dependencyMemberLayers =
          builtins.filter (layer: layer != null) (map memberLayerOf internalDeps);
        # Common artifact prefix for this member. In L an internal dependency's
        # layer already chains to it through `.prev`, so no explicit join is
        # needed; F replaces this ladder with
        # `mkCargoArtifactsJoin ([prefixNode] ++ dependencyMemberLayers)`.
        prefixNode =
          if !workspaceMode
          then packageCargoArtifacts
          else sharedDepsBase;
        dependencyArtifacts =
          if dependencyMemberLayers == []
          then prefixNode
          else if builtins.length dependencyMemberLayers == 1
          then builtins.head dependencyMemberLayers
          else
            mkCargoArtifactsJoin pkgs {
              name = pname;
              deps = dependencyMemberLayers;
            };
        # Artifacts-only layer for this member: it compiles the member exactly
        # once and publishes `$out/target.tar.zst`, while the deployed package
        # inherits it so build artifacts never enter the package runtime closure.
        memberLayer =
          if !workspaceMode
          then null
          else
            craneLib.cargoBuild (
              craneCommonAttrs
              // {
                cargoArtifacts = dependencyArtifacts;
                cargoExtraArgs = shellWords resolvedCraneBuildCargoArgs;
                doInstallCargoArtifacts = true;
              }
            );
        cargoArtifacts =
          if workspaceMode
          then memberLayer
          else builtins.seq internalDepsGuard packageCargoArtifacts;
        mkCraneCheckAttrs = extra:
          craneCommonAttrs
          // {
            inherit cargoArtifacts;
            doInstallCargoArtifacts = false;
            preBuild = rustCheckPreBuildPhase;
          }
          // extra;
      in {
        inherit memberLayer sharedDepsBase;
        build =
          if craneLib != null
          then
            craneLib.buildPackage (
              craneCommonAttrs
              // {
                inherit cargoArtifacts;
                cargoExtraArgs = shellWords resolvedCraneBuildCargoArgs;
              }
            )
          else
            pkgs.rustPlatform.buildRustPackage (
              commonAttrs
              // {
                cargoLock = resolvedCargoLock;
              }
              // (attrIf (projectDir != null) "buildAndTestSubdir" projectDir)
            );
        checks =
          if craneLib == null
          then null
          else {
            build =
              if build == null
              then null
              else build;
            fmt = craneLib.cargoFmt (
              craneCommonAttrs
              // {
                cargoExtraArgs = shellWords resolvedFmtCargoArgs;
                nativeBuildInputs = (commonAttrs.nativeBuildInputs or []) ++ resolvedFmtNativeBuildInputs;
              }
            );
            lint = craneLib.cargoClippy (mkCraneCheckAttrs {
              cargoExtraArgs = shellWords resolvedCraneCheckCargoArgs;
              cargoClippyExtraArgs = shellWords checkLintArgs;
              nativeBuildInputs = (commonAttrs.nativeBuildInputs or []) ++ resolvedLintNativeBuildInputs;
            });
            test = craneLib.cargoTest (mkCraneCheckAttrs {
              doCheck = true;
              cargoExtraArgs = shellWords resolvedCraneTestCargoArgs;
              nativeBuildInputs = (commonAttrs.nativeBuildInputs or []) ++ resolvedNativeCheckInputs;
            });
          };
      };
    resolvedBuild =
      if build != null
      then build
      else rustBuildPlan.build;
    bundle = mkPackageOpsBundle {
      inherit pkgs src pname projectPath;
      apps = {
        fmt = {
          parts = [
            (projectFmtRust pkgs {cargoArgs = resolvedFmtCargoArgs;})
            {
              inputs = resolvedFmtNativeBuildInputs;
            }
          ];
          commands = ["exec ${rustFmtCommand resolvedFmtCargoArgs} \"$@\""];
        };
        "lint-fix" = {
          parts = [
            (projectLintFixRust pkgs {
              cargoArgs = lintFixCargoArgs;
              lintArgs = lintFixLintArgs;
            })
            {
              inputs = resolvedLintNativeBuildInputs;
            }
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
              inputs =
                [
                  pkgs.cargo
                  pkgs.rustfmt
                ]
                ++ resolvedFmtNativeBuildInputs;
            }
          ];
          env = checkEnv;
          commands = [(rustFmtCheckCommand resolvedFmtCargoArgs)];
        };
        lint = {
          parts = [
            {
              inputs =
                [
                  pkgs.cargo
                  pkgs.clippy
                  pkgs.rustc
                ]
                ++ resolvedLintNativeBuildInputs;
            }
          ];
          env = checkEnv;
          commands = [(rustClippyCheckCommand resolvedCheckCargoArgs checkLintArgs)];
        };
        test = {
          parts = [
            {
              inputs =
                [
                  pkgs.cargo
                  pkgs.rustc
                ]
                ++ resolvedNativeCheckInputs;
            }
          ];
          env = checkEnv;
          commands = [(rustTestCommand resolvedTestCargoArgs)];
        };
      };
      devShellPackages = null;
    };
    basePassthru =
      (attrIf (sourcePath != null) "sourcePath" sourcePath)
      // (attrIf (rustBuildPlan != null && rustBuildPlan.memberLayer != null) "memberLayer" rustBuildPlan.memberLayer)
      // (attrIf (rustBuildPlan != null && rustBuildPlan.sharedDepsBase != null) "sharedDepsBase" rustBuildPlan.sharedDepsBase)
      // (attrIf (projectDir != null) "projectDir" projectDir)
      // {
        inherit (bundle) fmt;
        "lint-fix" = bundle."lint-fix";
        checks =
          if rustBuildPlan != null && rustBuildPlan.checks != null
          then {build = resolvedBuild;} // (builtins.removeAttrs rustBuildPlan.checks ["build"])
          else
            mkChecks resolvedBuild (mkRustCheckSpecs {
              inherit pkgs;
              clippyCargoArgs = resolvedCheckCargoArgs;
              clippyLintArgs = checkLintArgs;
              fmtCargoArgs = resolvedFmtCargoArgs;
              fmtNativeBuildInputs = resolvedFmtNativeBuildInputs;
              lintNativeBuildInputs = resolvedLintNativeBuildInputs;
              nativeCheckInputs = resolvedNativeCheckInputs;
              preBuildPhase = rustCheckPreBuildPhase;
              testCargoArgs = resolvedTestCargoArgs;
            });
        inherit (bundle) pkgOps;
      };
    devShellPassthru = attrIf enableDevShell "devShell" (pkgs.mkShell {
      packages = pkgs.lib.unique (
        devShellPackages
        ++ [
          pkgs.clippy
          pkgs.rustfmt
        ]
        ++ resolvedFmtNativeBuildInputs
        ++ resolvedLintNativeBuildInputs
        ++ resolvedNativeCheckInputs
        ++ extraDevShellPackages
      );
    });
    baseDrv = wirePassthru resolvedBuild (basePassthru // devShellPassthru);
    resolvedExtraPassthru =
      if builtins.isFunction extraPassthru
      then extraPassthru baseDrv
      else extraPassthru;
    drv =
      if resolvedExtraPassthru == {}
      then baseDrv
      else wirePassthru baseDrv resolvedExtraPassthru;
  in
    drv;

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
        then passthru.nixosModule
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
