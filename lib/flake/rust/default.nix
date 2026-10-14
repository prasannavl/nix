# Language implementation; pkg-helper.nix supplies the shared operations.
{
  common,
  pkgHelper,
}: let
  inherit (common) attrIf deriveProjectName deriveProjectPath exportEnv exportLiteralEnv hasPrefix inferBuildSrc isDerivation joinLines joinWords mkChecks mkPackageOpsBundle mkProjectApp mkProjectCommandsApp shellWords stripPrefix wirePassthru;
  compileContext = import ./compile-context.nix;
  sourceClosures = import ./closures.nix;

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
    else (import ./toolchain.nix {inherit pkgs;}).toolchainFor toolchain;

  defaultCargoPackageArgs = pkgs: projectDir: pname:
    ["--locked"]
    ++ pkgs.lib.optionals (projectDir != null) ["-p" pname];

  craneWorkspaceCargoArgs = projectDir: cargoArgs:
    if projectDir == null
    then cargoArgs
    else ["--offline"] ++ builtins.filter (arg: arg != "--locked" && arg != "--offline") cargoArgs;

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

  # importCargoLock vendors the supplied lock but does not install it in the
  # source tree. Keep explicit lock overrides coherent with cargoSetupHook's
  # comparison, after caller patches and before the setup hook. Unchanged locks
  # preserve existing derivation identities; opaque sources are never read here.
  buildRustPlatformPackage = rustPlatform: sourceInfo: attrs: let
    lock = attrs.cargoLock or {};
    lockContents =
      if !builtins.isAttrs lock
      then null
      else if (lock.lockFileContents or null) != null
      then lock.lockFileContents
      else if builtins.isPath (lock.lockFile or null)
      then builtins.readFile lock.lockFile
      else null;
    vendorUsesLock = (attrs.cargoDeps or null) == null && (attrs.cargoVendorDir or null) == null;
    actualSource = attrs.src or null;
    effectiveSource =
      if builtins.isPath actualSource
      then actualSource
      else if actualSource != null && sourceInfo.buildSrc != null && toString actualSource == toString sourceInfo.buildSrc
      then sourceInfo.src
      else null;
    sourceLock =
      effectiveSource
      + "/${
        if (attrs.cargoRoot or null) == null
        then ""
        else "${attrs.cargoRoot}/"
      }Cargo.lock";
    sourceMatchesLock =
      builtins.isPath effectiveSource
      && builtins.pathExists sourceLock
      && builtins.readFile sourceLock == lockContents;
    lockAttrs =
      if !vendorUsesLock || lockContents == null || sourceMatchesLock
      then {}
      else {
        rustPlatformLockfile = lockContents;
        passAsFile = (attrs.passAsFile or []) ++ ["rustPlatformLockfile"];
        postPatch = joinLines [
          (attrs.postPatch or "")
          ''
            cp --remove-destination -- "$rustPlatformLockfilePath" "''${cargoRoot:+$cargoRoot/}Cargo.lock"
          ''
        ];
      };
  in
    rustPlatform.buildRustPackage (attrs // lockAttrs);

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
    helper = pkgHelper;
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
        mkTrunkProject = args: unqualified (args.src or ../../..) (helper.mkTrunkProject (bind args));
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

  mkTrunkProject = {
    pkgs,
    toolchain ? null,
    src ?
      if projectDir == null
      then throw "pkg-helper.mkTrunkProject: pass `src` when `projectDir` is null"
      else ../../..,
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
          buildRustPlatformPackage pkgs.rustPlatform {inherit src buildSrc;} (
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
      (buildRustPlatformPackage rustPlatform {
        src = attrs.src or null;
        buildSrc = attrs.src or null;
      } (attrs // fallbackAttrs))
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
        buildRustPlatformPackage pkgs.rustPlatform {
          src = src;
          buildSrc = src;
        } (
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

  mkRustDerivation = {
    pkgs,
    toolchain ? null,
    build ? null,
    src ?
      if build == null
      then
        if projectDir == null
        then throw "pkg-helper.mkRustDerivation: pass `src` when `projectDir` is null"
        else ../../..
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
            buildRustPlatformPackage pkgs.rustPlatform {inherit src buildSrc;} (
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
}
