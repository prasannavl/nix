let
  compileContext = import ./rust-compile-context.nix;
  sourceClosures = import ./rust-closures.nix;

  # Private data context, never a callback/certificate or a producer input.
  # Validate the effective source BEFORE any scoped planner or constructor read.
  rustSourcePlan = sourceContext: src:
    if sourceContext == null
    then sourceClosures.plan {inherit src;}
    else if
      !builtins.isAttrs sourceContext
      || builtins.attrNames sourceContext != ["memberDirs" "src"]
      || !builtins.isPath src
      || !builtins.isPath sourceContext.src
      || toString src != toString sourceContext.src
    then throw "pkg-helper.forRustSource: effective src must match the bound evaluator-visible source"
    else
      sourceClosures.plan {
        inherit src;
        memberDirs = sourceContext.memberDirs;
      };

  scopedSourceGuard = sourceContext: src: let
    topology = rustSourcePlan sourceContext src;
  in
    if sourceContext == null
    then true
    else if !topology.supported
    then throw "pkg-helper.forRustSource: unsupported scoped declared-source workspace"
    else true;

  rustConsumerBuildArgs = args:
    builtins.removeAttrs args [
      "pkgs"
      "build"
      "src"
      "pname"
      "version"
      "projectDir"
      "projectPath"
      "deps"
      "toolchain"
      "useWorkspaceDeps"
      "internalDeps"
      "base"
      "baseLabel"
      "__rustSourceContext"
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

  consumerContext = args:
    compileContext.projectConsumer {
      selectedToolchain = selectToolchain args.pkgs (args.toolchain or null);
      buildArgs = rustConsumerBuildArgs args;
      inherit args;
    };

  selectToolchain = pkgs: toolchain:
    if pkgs ? rustToolchainFor
    then pkgs.rustToolchainFor toolchain
    else (import ./rust-toolchain.nix {inherit pkgs;}).toolchainFor toolchain;

  joinWords = parts:
    builtins.concatStringsSep " " (builtins.filter (part: part != "") parts);

  joinLines = lines:
    builtins.concatStringsSep "\n" (builtins.filter (line: line != "") lines);

  exportEnvWith = serialize: env:
    joinLines (builtins.attrValues (builtins.mapAttrs (name: value: "export ${name}=${serialize value}") env));

  # Keep old shell expansion semantics on compatibility paths only. Projected
  # discovery values are literals, including dollar signs and single quotes.
  exportEnv = exportEnvWith builtins.toJSON;
  exportLiteralEnv = exportEnvWith (value: "'${builtins.replaceStrings ["'"] ["'\\''"] value}'");

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
  # reader does not expand them, so such a member falls back to the isolated
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
    # package falls back to the correct isolated per-package path) instead of
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
  mkSharedRustDepsBase = {
    craneLib,
    source,
    cargoLockContents,
    cargoVendorDir,
  }:
    craneLib.buildDepsOnly {
      dummySrc = craneLib.mkDummySrc {src = source;};
      pname = "abird-rust-workspace";
      version = "0.1.0";
      cargoExtraArgs = "--offline --workspace";
      inherit cargoLockContents cargoVendorDir;
    };

  # Version 1 is deliberately unchained and narrow. Recipes describe source
  # selection only: neither caller metadata nor rustToolchainId certifies inputs.
  # Admission reconstructs this producer using the consumer's actual Crane
  # scope (bound tools, stdenv, scripts and hooks), lock, vendor and source.
  # This assumes trusted Nix configuration, not hostile custom Nix functions,
  # and is not qualification of Cargo's exact units or proof of artifact reuse.
  closureBaseRecipe = projectDir: sourceDirs: {
    version = 1;
    projectDir = normalizeMemberPath projectDir;
    inherit sourceDirs;
  };

  closureBaseSourceGuard = {
    pkgs,
    craneLib,
    src,
    projectDir,
    sourceDirs,
    sourceContext ? null,
  }: let
    fail = message: throw "pkg-helper.mkClosureBase: ${message}";
    topology = rustSourcePlan sourceContext src;
    member = normalizeMemberPath projectDir;
    root = builtins.fromTOML (builtins.readFile (src + "/Cargo.toml"));
    effectiveStdenv =
      if craneLib ? callPackage
      then
        craneLib.callPackage ({
          pkgs,
          stdenvSelector,
        }:
          stdenvSelector pkgs) {}
      else (craneLib.stdenvSelector or (p: p.stdenv)) pkgs;
    platform = p: {
      system = p.system;
      config = p.config or p.system;
    };
    native = s: platform s.buildPlatform == platform (s.hostPlatform or s.buildPlatform);
    # Verify that the existing awk rewrite really preserves the parsed manifest
    # and selects these directories. Inline/indented or otherwise unsupported
    # member-list formatting must not silently build a wider workspace.
    rewritten =
      builtins.foldl' (state: line:
        if builtins.match "members = \\[.*" line != null
        then {
          skipping = true;
          lines = state.lines ++ ["members = ["] ++ map (d: "  ${builtins.toJSON d},") sourceDirs;
        }
        else if state.skipping && builtins.match "].*" line != null
        then {
          skipping = false;
          lines = state.lines ++ [line];
        }
        else if state.skipping
        then state
        else state // {lines = state.lines ++ [line];})
      {
        skipping = false;
        lines = [];
      }
      (pkgs.lib.splitString "\n" (builtins.readFile (src + "/Cargo.toml")));
    projectedRoot = builtins.fromTOML (builtins.concatStringsSep "\n" rewritten.lines);
  in
    if craneLib == null
    then fail "requires Crane"
    else if !builtins.isPath src || projectDir == null
    then fail "requires an evaluator-visible path source and workspace projectDir"
    else if !native pkgs.stdenv || !native effectiveStdenv || platform effectiveStdenv.buildPlatform != platform pkgs.stdenv.buildPlatform
    then fail "closure bases support native contexts only"
    else if !topology.supported || !(builtins.hasAttr member topology.plan.closureDirs)
    then fail "unsupported declared-source workspace or member"
    else if builtins.sort builtins.lessThan sourceDirs != topology.plan.closureDirs.${member}
    then fail "actual selected source directories must equal the member's declared closure"
    else if ((builtins.readDir src)."Cargo.lock" or null) != "regular"
    then fail "requires a regular full workspace Cargo.lock"
    else if root ? profile || builtins.any (d: (builtins.fromTOML (builtins.readFile (src + "/${d}/Cargo.toml"))) ? profile) sourceDirs
    then fail "closure bases do not support custom Cargo profiles"
    else if rewritten.skipping || projectedRoot != (root // {workspace = root.workspace // {members = sourceDirs;};})
    then fail "unsupported workspace member-list rewrite"
    else true;

  constructClosureBase = {
    craneLib,
    source,
    sourceDirs,
    projectDir,
    cargoLockContents,
    cargoVendorDir,
    parent ? null,
    compilerAttrs ? {},
  }: let
    # mkDummySrc serializes cleaned manifests: the real-source awk formatting
    # cannot be assumed on its output. Project the cleaned virtual root through
    # Crane's own writer instead, after its normal dummy generation. This is a
    # build-time copy, never an evaluator read of the generated TOML (no IFD).
    cleanedRoot = craneLib.cleanCargoToml {
      cargoToml = builtins.unsafeDiscardStringContext (toString source) + "/Cargo.toml";
    };
    projectedRoot = craneLib.writeTOML "Cargo.toml" (cleanedRoot
      // {
        workspace = cleanedRoot.workspace // {members = sourceDirs;};
      });
    # Crane copies newly generated TOML after its recursive chmod, leaving the
    # root read-only. Make only that existing file writable before overwriting.
    projectRootScript = ''
      chmod u+w "$out/Cargo.toml"
      cp ${projectedRoot} "$out/Cargo.toml"
    '';
    unchainedProducer = craneLib.buildDepsOnly {
      dummySrc = craneLib.mkDummySrc {
        src = source;
        extraDummyScript = projectRootScript;
      };
      pname = "rust-closure-base";
      version = "1";
      inherit cargoLockContents cargoVendorDir;
      # Preserve Crane's release profile, check/build/test --no-run priming,
      # CRANE_BUILD_DEPS_ONLY marker and actual dummy src. No command overrides.
      cargoExtraArgs = "--offline --workspace";
      doCheck = true;
    };
    # buildDepsOnly forcibly sets cargoArtifacts = null. For a chain, reproduce
    # its pinned default recipe via mkCargoDerivation with the *actual* dummy
    # as src (dummySrc is not an argument understood by mkCargoDerivation).
    chainedProducer = craneLib.mkCargoDerivation {
      src = craneLib.mkDummySrc {
        src = source;
        extraDummyScript = projectRootScript;
      };
      pname = "rust-closure-base";
      pnameSuffix = "-deps";
      version = "2";
      inherit cargoLockContents cargoVendorDir;
      cargoArtifacts = parent;
      doCheck = true;
      doInstallCargoArtifacts = true;
      env.CRANE_BUILD_DEPS_ONLY = 1;
      # The empty build-extra-args slot retains Crane's exact default command.
      buildPhaseCargoCommand = ''
        cargoWithProfile check --offline --workspace --all-targets
        cargoWithProfile build --offline --workspace ${""}
      '';
      checkPhaseCargoCommand = ''
        cargoWithProfile test --offline --workspace --no-run
      '';
    };
    producer =
      if parent == null
      then unchainedProducer
      else chainedProducer;
    contextualProducer =
      if compilerAttrs == {}
      then producer
      else
        producer.overrideAttrs (old:
          compilerAttrs
          // (attrIf (compilerAttrs ? nativeBuildInputs) "nativeBuildInputs"
            (compilerAttrs.nativeBuildInputs ++ (old.nativeBuildInputs or [])))
          // {env = (old.env or {}) // (compilerAttrs.env or {});});
    recipe = closureBaseRecipe projectDir sourceDirs;
  in
    contextualProducer.overrideAttrs (old: {
      passthru =
        (old.passthru or {})
        // {
          rustClosureBaseRecipe =
            if parent == null
            then recipe
            else
              recipe
              // {
                version = 2;
                parent = parent.passthru.rustClosureBaseRecipe;
              };
        }
        // (
          if parent == null
          then {}
          else {rustClosureBaseParent = parent;}
        );
    });

  # Recipes select sources, never tools or arbitrary source trees. Reconstruct
  # every actual handle in the original consumer context, then compare all three
  # output identity fields. Check visited members BEFORE descending or comparing
  # recursive recipe descriptions, so forged cyclic passthru is bounded.
  reconstructClosureBase = {
    pkgs,
    craneLib,
    src,
    cargoLockContents,
    cargoVendorDir,
    base,
    visited ? [],
    withinDirs ? null,
    compilerAttrs ? {},
    sourceContext ? null,
  }: let
    fail = message: throw "pkg-helper.mkClosureBase: ${message}";
    recipe = base.passthru.rustClosureBaseRecipe or null;
    version = recipe.version or null;
    member = recipe.projectDir;
    dirs = recipe.sourceDirs;
    actualParent = base.passthru.rustClosureBaseParent or null;
    parent =
      if version == 1
      then null
      else
        reconstructClosureBase {
          inherit pkgs craneLib src cargoLockContents cargoVendorDir compilerAttrs sourceContext;
          base = actualParent;
          visited = visited ++ [member];
          withinDirs = dirs;
        };
    expected = constructClosureBase {
      inherit craneLib cargoLockContents cargoVendorDir parent compilerAttrs;
      projectDir = member;
      sourceDirs = dirs;
      source = mkWorkspaceSourcePath pkgs {
        inherit src;
        selectedDirs = dirs;
      };
    };
  in
    if !isDerivation base || !builtins.isAttrs recipe
    then fail "opaque or malformed closure base recipe"
    else if
      !(builtins.elem version [1 2])
      || builtins.attrNames recipe
      != (
        if version == 1
        then ["projectDir" "sourceDirs" "version"]
        else ["parent" "projectDir" "sourceDirs" "version"]
      )
      || !builtins.isString (recipe.projectDir or null)
      || !builtins.isList (recipe.sourceDirs or null)
      || !builtins.all builtins.isString dirs
    then fail "unknown or malformed closure base recipe"
    else if member != normalizeMemberPath member
    then fail "malformed noncanonical closure base member"
    else if builtins.elem member visited
    then fail "cyclic closure base parent at member ${member}"
    else if withinDirs != null && (!(builtins.length dirs < builtins.length withinDirs) || !builtins.all (d: builtins.elem d withinDirs) dirs)
    then fail "parent closure must be a strict subset of the consumer closure"
    else if (version == 1 && actualParent != null) || (version == 2 && !isDerivation actualParent)
    then fail "malformed closure base parent handle"
    else
      builtins.seq (closureBaseSourceGuard {
        inherit pkgs craneLib src sourceContext;
        projectDir = member;
        sourceDirs = dirs;
      }) (
        builtins.seq parent (
          if version == 2 && recipe.parent != parent.passthru.rustClosureBaseRecipe
          then fail "mismatched recursive parent recipe"
          else if
            (base.drvPath or null)
            != expected.drvPath
            || (base.outputName or null) != expected.outputName
            || (base.outPath or null) != expected.outPath
          then fail "reconstructed closure base derivation/output mismatch"
          else expected
        )
      );

  # Join several members' artifact layers into one self-contained archive. Crane
  # chains a single `.prev` parent, so a member with two or more in-repo
  # dependencies needs an explicit join. This materialises the union as one full
  # archive (simple and correct); it is only needed when fan-in occurs.
  mkCargoArtifactsJoin = {
    craneLib,
    name,
    deps,
  }:
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
  # Source diagnostics only; this does not select bases or resolve Cargo units.
  rustPlan = sourceClosures.plan;

  # Preserve the generic helper API without copying/forking its implementation.
  # Only source-sensitive Rust entry points close over this private context.
  forRustSource = {
    src,
    memberDirs,
  }: let
    sourceContext = {inherit src memberDirs;};
    helper = import ./pkg-helper.nix;
    topology = rustSourcePlan sourceContext src;
    bind = args:
      if args ? __rustSourceContext
      then throw "pkg-helper.forRustSource: private source context cannot be overridden"
      else args // {__rustSourceContext = sourceContext;};
    unqualified = effectiveSrc: value:
      builtins.seq (scopedSourceGuard sourceContext effectiveSrc) (
        if topology.metadata.sourceScope.properSubset
        then throw "pkg-helper.forRustSource: proper-subset sources require the guarded member-base route"
        else value
      );
    bound =
      helper
      // {
        rustPlan = args:
          if builtins.attrNames args != ["src"]
          then throw "pkg-helper.forRustSource: rustPlan accepts only the bound src"
          else rustSourcePlan sourceContext args.src;
        mkClosureBase = args: helper.mkClosureBase (bind args);
        mkRustDerivation = args: helper.mkRustDerivation (bind args);
        mkRustComposition = args:
          builtins.seq (scopedSourceGuard sourceContext args.src)
          ((import ./member-bases.nix) {
              pkgHelper = {
                consumerContext = consumerContext;
                inherit (bound) mkClosureBase mkRustDerivation rustPlan;
              };
            }
            args);
        # These adapters do not implement explicit closure-base admission. Keep
        # their full-source operation, but never fall back on a partial workspace.
        mkCargoWorkspacePackage = args: unqualified args.src (helper.mkCargoWorkspacePackage (bind args));
        mkTrunkProject = args: unqualified (args.src or ../..) (helper.mkTrunkProject (bind args));
        mkCraneRustPackage = args: unqualified args.attrs.src (helper.mkCraneRustPackage (bind args));
      };
  in
    builtins.seq (scopedSourceGuard sourceContext src) bound;

  # Small constructor matching mkRustDerivation's source/toolchain context.
  # deps must supply exactly the declared closure beyond projectDir. Full root
  # lock and its vendor are shared. parent is an internal composition seam,
  # restricted to genuine strict-subset closure bases, not a user cache toggle.
  mkClosureBase = {
    pkgs,
    src,
    projectDir,
    deps ? [],
    toolchain ? null,
    parent ? null,
    buildAttrs ? {},
    __rustSourceContext ? null,
  }: let
    sourceContext = __rustSourceContext;
    selectedToolchain = selectToolchain pkgs toolchain;
    craneLib = selectedToolchain.craneLib;
    compilerAttrs = compileContext.projectRecord {
      inherit selectedToolchain;
      record = buildAttrs;
    };
    sourceDirs = map normalizeMemberPath ([projectDir] ++ pkgs.lib.unique deps);
    source = mkWorkspaceSourcePath pkgs {
      inherit src;
      selectedDirs = sourceDirs;
    };
    cargoLockContents = builtins.readFile (src + "/Cargo.lock");
    cargoVendorDir = craneLib.vendorCargoDeps {inherit cargoLockContents;};
    admittedParent =
      if parent == null
      then null
      else
        reconstructClosureBase {
          inherit pkgs craneLib src cargoLockContents cargoVendorDir compilerAttrs sourceContext;
          base = parent;
          visited = [normalizeMemberPath projectDir];
          withinDirs = sourceDirs;
        };
  in
    builtins.seq (scopedSourceGuard sourceContext src) (builtins.seq compilerAttrs (builtins.seq (closureBaseSourceGuard {inherit pkgs craneLib src projectDir sourceDirs sourceContext;})
      (builtins.seq admittedParent (constructClosureBase {
        inherit craneLib source sourceDirs projectDir cargoLockContents cargoVendorDir compilerAttrs;
        # Inherit the actual handle, after identity verification; do not turn a
        # descriptive recipe into authority for a substituted parent.
        parent = parent;
      }))));

  mkRustComposition = (import ./member-bases.nix) {
    pkgHelper = {inherit mkClosureBase mkRustDerivation consumerContext rustPlan;};
  };

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
    toolchain ? null,
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
    __rustSourceContext ? null,
  }: let
    selectedToolchain = selectToolchain pkgs toolchain;
    toolPkgs = selectedToolchain.toolPkgs;
    craneLib = selectedToolchain.craneLib;
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
        toolPkgs.cargo
        pkgs.git
        toolPkgs.rustc
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
      builtins.seq (selectedToolchain.validateBuildAttrs trunkBuildAttrs) (
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
        else if selectedToolchain.custom
        then throw "pkg-helper.mkTrunkProject: custom toolchain cannot use the rustPlatform/cargoDeps fallback"
        else
          pkgs.rustPlatform.buildRustPackage (
            trunkBuildAttrs
            // {
              cargoLock = resolvedCargoLock;
            }
            // (attrIf (projectDir != null) "buildAndTestSubdir" projectDir)
          )
      );
    drv = mkRustDerivation {
      projectDir = projectPath;
      inherit pkgs toolchain src pname fmtCargoArgs lintFixCargoArgs checkCargoArgs testCargoArgs cargoBuildArgs;
      # This helper actually produced the custom Crane build; certify its
      # identity before passing it through the supplied-build adapter.
      build =
        if selectedToolchain.custom
        then wirePassthru build {rustToolchainId = selectedToolchain.id;}
        else build;
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
    builtins.seq (scopedSourceGuard __rustSourceContext ({inherit src;} // buildAttrsNoPrePatch).src)
    (wirePassthru baseDrv resolvedExtraPassthru);

  mkCraneRustPackage = {
    attrs,
    cargoExtraArgs ? "--locked",
    craneLib ? null,
    depsOnlyAttrs ? {},
    finalAttrs ? {},
    rustPlatform,
    fallbackAttrs ? finalAttrs,
    __rustSourceContext ? null,
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
    then
      builtins.seq (scopedSourceGuard __rustSourceContext (attrs // fallbackAttrs).src)
      (rustPlatform.buildRustPackage (attrs // fallbackAttrs))
    else
      builtins.seq (scopedSourceGuard __rustSourceContext finalMergedAttrs.src)
      (builtins.seq (scopedSourceGuard __rustSourceContext depsOnlyMergedAttrs.src)
        (craneLib.buildPackage (
          withCargoSetupHook finalMergedAttrs
          // {
            inherit cargoArtifacts;
            cargoExtraArgs = cargoExtraArgs;
          }
        )));

  mkCargoWorkspacePackage = {
    pkgs,
    toolchain ? null,
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
    __rustSourceContext ? null,
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
      "toolchain"
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
      "__rustSourceContext"
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
      else if (selectToolchain pkgs toolchain).custom
      # rustPlatform's build/test flag semantics are not interchangeable with
      # Crane's cargoExtraArgs. Until this adapter translates both faithfully,
      # never silently ignore distinct test args or cargoBuild/TestFlags.
      then throw "pkg-helper.mkCargoWorkspacePackage: custom toolchain builds are not supported yet; use mkRustDerivation without a supplied build, or supply a build with a matching producer rustToolchainId"
      else
        pkgs.rustPlatform.buildRustPackage (
          commonBuildAttrs
          // {
            cargoLock = resolvedCargoLock;
          }
        );
  in
    builtins.seq (scopedSourceGuard __rustSourceContext (
      if build == null
      then commonBuildAttrs.src
      else inferBuildSrc build
    )) (mkRustDerivation (
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
    ));

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
    toolchain ? null,
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
    # REVIEW (abird post-278a2cba port): the `pkgs.rustWorkspaceDeps`
    # repository-policy default is the Abird c50d5c57 seam; revisit after the
    # rust fabric work lands in both repositories.
    useWorkspaceDeps ? pkgs.rustWorkspaceDeps or (projectDir != null),
    internalDeps ? [],
    base ? null,
    # Diagnostic only: never a producer parameter or derivation input.
    baseLabel ? null,
    __rustSourceContext ? null,
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
    sourceContext = __rustSourceContext;
    # Validate the actual merged root source, before filtering or compiler
    # projection. Internal source projections are not caller source overrides.
    rootBuildAttrs =
      if build == null
      then {inherit src;} // buildArgs // buildAttrs
      else {src = inferBuildSrc build;};
    scopeGuard = builtins.seq (scopedSourceGuard sourceContext src) (
      builtins.seq (scopedSourceGuard sourceContext rootBuildAttrs.src) (
        if sourceContext == null
        then true
        else if (rustSourcePlan sourceContext src).metadata.sourceScope.properSubset && (base == null || build != null)
        then throw "pkg-helper.mkRustDerivation: proper-subset sources require an admitted member closure base and cannot use a supplied build"
        else true
      )
    );
    selectedToolchain = selectToolchain pkgs toolchain;
    toolPkgs = selectedToolchain.toolPkgs;
    craneLib = selectedToolchain.craneLib;
    buildContractGuard =
      builtins.seq
      (selectedToolchain.validateBuildAttrs (buildArgs // buildAttrs))
      (selectedToolchain.validateBuildAttrs {env = checkEnv;});
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
    buildArgs = rustConsumerBuildArgs args;
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
        # In-repo workspace members share one dummy-sourced dependency base (see
        # `sharedDepsBase` below). Member layers keep their own per-member source
        # so that editing one member's `*.rs` only invalidates that member and
        # its dependents. Every other shape (no `projectDir`, no crane,
        # non-member) keeps the isolated per-package behavior.
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
          (
            if !expanded
            then commonAttrs
            else
              {
                inherit pname version;
                src = buildSrc;
                prePatch = buildPrePatch;
              }
              // compilerAttrs
          )
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
        actualSourceDirs = map normalizeMemberPath ([projectDir] ++ resolvedDeps);
        # Preserve the original zero-context admission predicate and route.
        oldExplicitAdmission =
          !(
            buildArgs
            != {}
            || buildAttrs != {}
            || prePatch != ""
            || cargoLock != null
            || resolvedNativeCheckInputs != []
            || resolvedFmtNativeBuildInputs != []
            || resolvedLintNativeBuildInputs != []
            || checkEnv != {}
            || resolvedBuildCargoArgs != defaultPackageCargoArgs
            || resolvedCheckCargoArgs != defaultPackageCargoArgs
            || resolvedTestCargoArgs != defaultPackageCargoArgs
            || checkLintArgs != ["--" "-D" "warnings"]
          );
        expanded = base != null && !oldExplicitAdmission;
        projected = consumerContext args;
        compilerAttrs =
          if expanded
          then projected.compileAttrs
          else {};
        packagingAttrs =
          if expanded
          then projected.packagingAttrs
          else {};
        expandedGuard = builtins.seq projected.compileAttrs (builtins.seq projected.packagingAttrs (
          if
            prePatch
            != ""
            || cargoLock != null
            || resolvedBuildCargoArgs != defaultPackageCargoArgs
            || resolvedCheckCargoArgs != defaultPackageCargoArgs
            || resolvedTestCargoArgs != defaultPackageCargoArgs
            || checkLintArgs != ["--" "-D" "warnings"]
          then throw "pkg-helper.mkRustDerivation: contextual closure base requires default build/check flags, full root lock and no source hooks"
          else true
        ));
        explicitBaseGuard =
          if base == null
          then true
          else if !(isDerivation base)
          then throw "pkg-helper.mkRustDerivation: base must be a derivation or null"
          else
            builtins.seq (
              if oldExplicitAdmission
              then true
              else expandedGuard
            )
            (builtins.seq internalDepsGuard (closureBaseSourceGuard {
              inherit pkgs craneLib src projectDir sourceContext;
              sourceDirs = actualSourceDirs;
            }));
        expectedBase = reconstructClosureBase {
          inherit pkgs craneLib src base compilerAttrs sourceContext;
          cargoLockContents = resolvedCraneCargoLockAttrs.cargoLockContents;
          cargoVendorDir = craneCargoVendorDir;
        };
        admittedBase = builtins.seq explicitBaseGuard (builtins.seq expectedBase (
          if
            expectedBase.passthru.rustClosureBaseRecipe.projectDir
            != normalizeMemberPath projectDir
            || expectedBase.passthru.rustClosureBaseRecipe.sourceDirs != actualSourceDirs
          then throw "pkg-helper.mkRustDerivation: mismatched closure base source selection"
          else base
        ));
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
          if base != null
          then null
          else if !workspaceMode
          then null
          else
            mkSharedRustDepsBase {
              craneLib = craneLib;
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
        # be isolated from workspace mode (`useWorkspaceDeps = false`)
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
        memberLayerOf = dep: let
          passthru = dep.passthru or {};
          layer = passthru.memberLayer or null;
        in
          if layer == null
          then null
          else if (passthru.rustToolchainId or null) != selectedToolchain.id
          then throw "pkg-helper.mkRustDerivation: internalDeps artifact toolchain mismatch (or missing rustToolchainId); compile from source via deps instead"
          else layer;
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
          if base != null
          then admittedBase
          else if dependencyMemberLayers == []
          then prefixNode
          else if builtins.length dependencyMemberLayers == 1
          then builtins.head dependencyMemberLayers
          else
            mkCargoArtifactsJoin {
              craneLib = craneLib;
              name = pname;
              deps = dependencyMemberLayers;
            };
        # Artifacts-only layer for this member: it compiles the member exactly
        # once and publishes `$out/target.tar.zst`, while the deployed package
        # inherits it so build artifacts never enter the package runtime closure.
        memberLayer =
          if !workspaceMode && base == null
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
          if base != null
          then builtins.seq admittedBase memberLayer
          else if workspaceMode
          then builtins.seq internalDepsGuard memberLayer
          else builtins.seq internalDepsGuard packageCargoArtifacts;
        # Packaging is downstream of every artifact producer and check.
        finalAttrs =
          if !expanded
          then {}
          else
            packagingAttrs
            // {
              doInstallCargoArtifacts = false;
              # A final phase, not the postInstall variable: runHook evaluates
              # that variable BEFORE setup-hook postInstallHooks. Check the
              # known output paths after installation and fixup have finished.
              # This does not attest arbitrary shell/setup-hook effects.
              postPhases = ["rustFinalOutputCheckPhase"];
              rustFinalOutputCheckPhase = ''
                for artifact in "$out/target" "$out/target.tar.zst" "$out/target.tar.zst.prev"; do
                  if [ -e "$artifact" ] || [ -L "$artifact" ]; then
                    echo "pkg-helper: final package must not publish Cargo artifacts: $artifact" >&2
                    exit 1
                  fi
                done
              '';
            };
        mkCraneCheckAttrs = extra:
          craneCommonAttrs
          // {
            inherit cargoArtifacts;
            doInstallCargoArtifacts = false;
            # Expanded checkEnv is redundant with the actual derivation env.
            # Do not replay it through shell exports (which can expand `$`).
            preBuild =
              if expanded
              then "cargo generate-lockfile --offline"
              else rustCheckPreBuildPhase;
          }
          // extra;
      in {
        inherit memberLayer sharedDepsBase expanded compilerAttrs;
        baseAdmission =
          if base == null
          then true
          else admittedBase;
        build =
          if craneLib != null
          then
            craneLib.buildPackage (
              craneCommonAttrs
              // {
                inherit cargoArtifacts;
                cargoExtraArgs = shellWords resolvedCraneBuildCargoArgs;
              }
              // finalAttrs
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
                nativeBuildInputs = (craneCommonAttrs.nativeBuildInputs or []) ++ resolvedFmtNativeBuildInputs;
              }
            );
            lint = craneLib.cargoClippy (mkCraneCheckAttrs {
              cargoExtraArgs = shellWords resolvedCraneCheckCargoArgs;
              cargoClippyExtraArgs = shellWords checkLintArgs;
              nativeBuildInputs =
                (craneCommonAttrs.nativeBuildInputs or [])
                ++ (
                  if expanded
                  then []
                  else resolvedLintNativeBuildInputs
                );
            });
            test = craneLib.cargoTest (mkCraneCheckAttrs {
              doCheck = true;
              cargoExtraArgs = shellWords resolvedCraneTestCargoArgs;
              nativeBuildInputs =
                (craneCommonAttrs.nativeBuildInputs or [])
                ++ (
                  if expanded
                  then []
                  else resolvedNativeCheckInputs
                );
            });
          };
      };
    producerPassthru =
      if build == null
      then {}
      else build.passthru or {};
    producerId = producerPassthru.rustToolchainId or null;
    suppliedBuildGuard =
      if base != null && build != null
      then throw "pkg-helper.mkRustDerivation: explicit base cannot be used with a supplied build"
      else if build == null
      then true
      else if (producerPassthru.memberLayer or null) != null && producerId != selectedToolchain.id
      then throw "pkg-helper.mkRustDerivation: supplied build memberLayer requires a matching producer rustToolchainId; artifacts cannot be relabeled"
      else if selectedToolchain.custom && producerId != selectedToolchain.id
      then throw "pkg-helper.mkRustDerivation: custom toolchain on a supplied build requires a matching producer rustToolchainId"
      else true;
    baseInjectionGuard =
      if base == null
      then true
      else if build != null
      then suppliedBuildGuard
      else rustBuildPlan.baseAdmission;
    resolvedBuild =
      if build != null
      then builtins.seq suppliedBuildGuard build
      else rustBuildPlan.build;
    bundle = mkPackageOpsBundle {
      inherit pkgs src pname projectPath;
      apps = {
        fmt = {
          parts = [
            (projectFmtRust toolPkgs {cargoArgs = resolvedFmtCargoArgs;})
            {
              inputs = resolvedFmtNativeBuildInputs;
            }
          ];
          commands = ["exec ${rustFmtCommand resolvedFmtCargoArgs} \"$@\""];
        };
        "lint-fix" = {
          parts = [
            (projectLintFixRust toolPkgs {
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
                  toolPkgs.cargo
                  toolPkgs.rustfmt
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
                  toolPkgs.cargo
                  toolPkgs.clippy
                  toolPkgs.rustc
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
                  toolPkgs.cargo
                  toolPkgs.rustc
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
      // (attrIf (base != null) "depsBase" base)
      // (attrIf (base != null && baseLabel != null) "baseLabel" baseLabel)
      # Only helper-produced builds receive an identity. Opaque supplied builds
      # retain their producer's ID (or its absence); their checks use toolPkgs,
      # but those checks do not prove which compiler produced the original build.
      // (attrIf (build == null) "rustToolchainId" selectedToolchain.id)
      // {
        inherit (bundle) fmt;
        "lint-fix" = bundle."lint-fix";
        checks =
          if rustBuildPlan != null && rustBuildPlan.checks != null
          then {build = resolvedBuild;} // (builtins.removeAttrs rustBuildPlan.checks ["build"])
          else
            mkChecks resolvedBuild (mkRustCheckSpecs {
              pkgs = toolPkgs;
              clippyCargoArgs = resolvedCheckCargoArgs;
              clippyLintArgs = checkLintArgs;
              fmtCargoArgs = resolvedFmtCargoArgs;
              fmtNativeBuildInputs = resolvedFmtNativeBuildInputs;
              lintNativeBuildInputs = resolvedLintNativeBuildInputs;
              nativeCheckInputs = resolvedNativeCheckInputs;
              preBuildPhase = rustCheckPreBuildPhase;
              testCargoArgs = resolvedTestCargoArgs;
            });
        # Private observation for export/shell adapters, not an artifact
        # certificate. Reuse the already-selected operation tools; never resolve
        # the factory's toolchain again or expose the recursive package set.
        __rustOperationContext = {
          # The writer is bound to the actual selected Crane library. This
          # observation is lazy passthru data, not a second compiler selector.
          writeTOML = craneLib.writeTOML;
          env =
            if rustBuildPlan == null
            then {}
            else rustBuildPlan.compilerAttrs.env or {};
        };
        actualOperationTools =
          builtins.intersectAttrs {
            cargo = null;
            rustc = null;
            clippy = null;
            rustfmt = null;
          }
          toolPkgs;
        pkgOps =
          if rustBuildPlan == null || !rustBuildPlan.expanded
          then bundle.pkgOps
          else
            bundle.pkgOps
            // {
              # projectConsumer already validates checkEnv as a redundant subset
              # of this normalized environment. No second merge/validator.
              checks = builtins.mapAttrs (_: spec:
                spec // {envScript = exportLiteralEnv (rustBuildPlan.compilerAttrs.env or {});})
              bundle.pkgOps.checks;
            };
      };
    devShellPassthru = attrIf enableDevShell "devShell" (pkgs.mkShell {
      packages = pkgs.lib.unique (
        (
          if args ? devShellPackages
          then devShellPackages
          else [toolPkgs.cargo pkgs.rust-analyzer toolPkgs.rustc]
        )
        ++ [
          toolPkgs.clippy
          toolPkgs.rustfmt
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
    builtins.seq scopeGuard (builtins.seq buildContractGuard (builtins.seq baseInjectionGuard drv));

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
