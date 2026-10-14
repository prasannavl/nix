# Pure mocks by default; pass cached real pkgs for identical construction tests.
# Evaluation only: this does not prove Cargo reuse or full incoming components.
{
  pkgs ? null,
  pkgHelper ? import ../../pkg-helper.nix,
}: let
  helper = pkgHelper;
  planner = import ../closures.nix;
  fixture = ./fixtures/source-scope;
  selectedSrc = fixture + "/selected";
  fullSrc = fixture + "/full";
  memberDirs = ["members/application" "members/leaf" "members/middle"];
  mkDrv = name: attrs: let
    hash = builtins.substring 0 32 (builtins.hashString "sha256" (builtins.toJSON (builtins.removeAttrs attrs ["passthru"])));
    path = "/nix/store/${hash}-${name}";
  in
    attrs
    // {
      type = "derivation";
      outPath = path;
      drvPath = "${path}.drv";
      outputName = "out";
      overrideAttrs = f: mkDrv name (attrs // f attrs);
    };
  build = name: attrs: mkDrv name attrs;
  mockPkgs = {
    craneLib = {
      cleanCargoToml = {cargoToml}: builtins.fromTOML (builtins.readFile cargoToml);
      writeTOML = name: data: build name {inherit data;};
      mkDummySrc = build "dummy";
      vendorCargoDeps = build "vendor";
      buildDepsOnly = attrs:
        build "deps" ((builtins.removeAttrs attrs ["dummySrc"])
          // {
            src = attrs.dummySrc;
            cargoArtifacts = null;
            env.CRANE_BUILD_DEPS_ONLY = 1;
            doInstallCargoArtifacts = true;
          });
      buildPackage = build "package";
      cargoBuild = build "member";
      cargoFmt = build "fmt";
      cargoClippy = build "lint";
      cargoTest = build "test";
      mkCargoDerivation = build "chained";
    };
    stdenv = {
      buildPlatform.system = "x86_64-linux";
      hostPlatform.system = "x86_64-linux";
    };
    cargo = mkDrv "cargo" {};
    rustc = mkDrv "rustc" {};
    clippy = mkDrv "clippy" {};
    rustfmt = mkDrv "rustfmt" {};
    runCommandLocal = name: attrs: script: mkDrv name (attrs // {inherit script;});
    runCommand = name: attrs: script: mkDrv name (attrs // {inherit script;});
    writeShellApplication = attrs: mkDrv attrs.name attrs;
    nix-gitignore.gitignoreFilterPure = _: _: _: _: _: true;
    lib = {
      optional = c: v:
        if c
        then [v]
        else [];
      optionals = c: v:
        if c
        then v
        else [];
      unique = xs:
        builtins.foldl' (acc: x:
          if builtins.elem x acc
          then acc
          else acc ++ [x]) []
        xs;
      splitString = sep: text: builtins.filter builtins.isString (builtins.split sep text);
    };
  };
  effectivePkgs =
    if pkgs == null
    then mockPkgs
    else pkgs;
  bound = helper.forRustSource {
    src = selectedSrc;
    inherit memberDirs;
  };
  fullBound = helper.forRustSource {
    src = fullSrc;
    memberDirs = memberDirs ++ ["members/peer"];
  };
  scoped = planner.plan {
    src = selectedSrc;
    inherit memberDirs;
  };
  root = builtins.fromTOML (builtins.readFile (fullSrc + "/Cargo.toml"));
  manifestMembers = (planner.readWorkspace {src = fullSrc;}).members;
  pure = attrs:
    planner.planFromManifests ({
        workspace = root;
        members = manifestMembers;
        inherit memberDirs;
      }
      // attrs);
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  reason = code: result: !result.supported && result.plan == null && builtins.any (r: r.code == code) result.reasons;
  ctx = {
    pkgs = effectivePkgs;
    src = selectedSrc;
  };
  fullCtx = ctx // {src = fullSrc;};
  leafArgs = {projectDir = "members/leaf";};
  middleArgs = {
    projectDir = "members/middle";
    deps = ["members/leaf"];
  };
  appArgs = {
    projectDir = "members/application";
    deps = ["members/leaf" "members/middle"];
    pname = "application";
  };
  scopedLeaf = bound.mkClosureBase (ctx // leafArgs);
  fullLeaf = helper.mkClosureBase (fullCtx // leafArgs);
  scopedV1 = bound.mkClosureBase (ctx // middleArgs);
  fullV1 = helper.mkClosureBase (fullCtx // middleArgs);
  scopedMiddle = bound.mkClosureBase (ctx // middleArgs // {parent = scopedLeaf;});
  fullMiddle = helper.mkClosureBase (fullCtx // middleArgs // {parent = fullLeaf;});
  scopedV2 = bound.mkClosureBase (ctx // (builtins.removeAttrs appArgs ["pname"]) // {parent = scopedMiddle;});
  fullV2 = helper.mkClosureBase (fullCtx // (builtins.removeAttrs appArgs ["pname"]) // {parent = fullMiddle;});
  scopedPackage = bound.mkRustDerivation (ctx // appArgs // {base = fullV2;});
  fullPackage = helper.mkRustDerivation (fullCtx // appArgs // {base = scopedV2;});
  composition = bound.mkRustComposition (ctx // {baseMode = "member";});
  fullComposition = helper.mkRustComposition (fullCtx // {baseMode = "member";});
  automaticPackage = composition.mkRustDerivation {
    projectDir = appArgs.projectDir;
    pname = appArgs.pname;
  };
  nativeAttrs = {
    nativeBuildInputs = [effectivePkgs.cargo effectivePkgs.cargo];
    env.OPENSSL_DIR = "literal-path";
    doCheck = false;
    postInstall = "echo packaging-only";
  };
  nativeScoped = bound.mkRustComposition (ctx
    // {
      baseMode = "member";
      buildAttrs = nativeAttrs;
    });
  nativeFull = helper.mkRustComposition (fullCtx
    // {
      baseMode = "member";
      buildAttrs = nativeAttrs;
    });
  nativeScopedPackage = nativeScoped.mkRustDerivation {
    projectDir = appArgs.projectDir;
    pname = appArgs.pname;
  };
  nativeFullPackage = nativeFull.mkRustDerivation {
    projectDir = appArgs.projectDir;
    pname = appArgs.pname;
  };
  output = drv: {inherit (drv) drvPath outputName outPath;};
  pair = a: b: {
    full = output a;
    scoped = output b;
  };
  equalityEvidence = {
    leafV1 = pair fullLeaf scopedLeaf;
    middleV1 = pair fullV1 scopedV1;
    middleV2 = pair fullMiddle scopedMiddle;
    applicationV2 = pair fullV2 scopedV2;
    final = pair fullPackage scopedPackage;
    member = pair fullPackage.passthru.memberLayer scopedPackage.passthru.memberLayer;
    fmt = pair fullPackage.passthru.checks.fmt scopedPackage.passthru.checks.fmt;
    lint = pair fullPackage.passthru.checks.lint scopedPackage.passthru.checks.lint;
    test = pair fullPackage.passthru.checks.test scopedPackage.passthru.checks.test;
    compositionBase = pair (fullComposition.baseFor appArgs.projectDir) (composition.baseFor appArgs.projectDir);
    compositionFinal = pair fullPackage automaticPackage;
    nativeBase = pair (nativeFull.baseFor appArgs.projectDir) (nativeScoped.baseFor appArgs.projectDir);
    nativeFinal = pair nativeFullPackage nativeScopedPackage;
    nativeMember = pair nativeFullPackage.passthru.memberLayer nativeScopedPackage.passthru.memberLayer;
    nativeFmt = pair nativeFullPackage.passthru.checks.fmt nativeScopedPackage.passthru.checks.fmt;
    nativeLint = pair nativeFullPackage.passthru.checks.lint nativeScopedPackage.passthru.checks.lint;
    nativeTest = pair nativeFullPackage.passthru.checks.test nativeScopedPackage.passthru.checks.test;
  };
  withDependency = kind: optional:
    pure {
      members =
        manifestMembers
        // {
          "members/application" =
            manifestMembers."members/application"
            // {
              ${kind}.peer = {
                path = "../peer";
                inherit optional;
              };
            };
        };
    };
  outside = planner.plan {
    src = fixture + "/outside-dependency";
    inherit memberDirs;
  };
  wrongSrc = ./fixtures/closures/invalid;
  overlapInputs = planner.readWorkspace {
    src = fixture + "/root-overlap";
    memberDirs = ["members"];
  };
  overlapScoped = planner.plan {
    src = fixture + "/root-overlap";
    memberDirs = ["members"];
  };
  # Recording constructors expose actual final/dependency attrs, independently
  # of the real-Crane identity evidence above. No source build is performed.
  adapterPkgs =
    mockPkgs
    // {
      rustToolchainFor = _: {
        toolPkgs = mockPkgs;
        craneLib = null;
        custom = false;
        id = "recording";
        validateBuildAttrs = _: true;
      };
      binaryen = mockPkgs.cargo;
      llvmPackages.lld = mockPkgs.cargo;
      rustPlatform.buildRustPackage = build "adapter-fallback";
    };
  adapterCrane = {
    buildPackage = build "adapter-final";
    buildDepsOnly = build "adapter-deps";
  };
  adapters = {
    rust = h: source: extra:
      h.mkRustDerivation ({
          pkgs = adapterPkgs;
          src = source;
          pname = "recording";
        }
        // extra);
    cargo = h: source: extra:
      h.mkCargoWorkspacePackage ({
          pkgs = adapterPkgs;
          src = source;
          pname = "recording";
        }
        // extra);
    trunk = h: source: extra:
      h.mkTrunkProject ({
          pkgs = adapterPkgs;
          src = source;
          pname = "recording";
          trunk = mockPkgs.cargo;
          wasmBindgenCli = mockPkgs.cargo;
        }
        // extra);
  };
  adapterAssertions = builtins.foldl' (acc: name: let
    call = adapters.${name};
    baseline = call helper fullSrc {};
    same = {buildAttrs.src = fullSrc;};
    foreign = {buildAttrs.src = wrongSrc;};
  in
    acc
    // {
      ${"fullScope" + name + "SourceOverrideRejected"} = fails (call fullBound fullSrc foreign).drvPath;
      ${"subset" + name + "SourceOverrideRejected"} = fails (call bound selectedSrc foreign).drvPath;
      ${"fullScope" + name + "DefaultIdentity"} = (call fullBound fullSrc {}).drvPath == baseline.drvPath;
      ${"fullScope" + name + "SameSourcePreserved"} = (call fullBound fullSrc same).drvPath == (call helper fullSrc same).drvPath;
      ${"unbound" + name + "SourceOverridePreserved"} = toString (call helper fullSrc foreign).src == toString wrongSrc;
      ${"nullContext" + name + "SourceOverridePreserved"} =
        (call helper fullSrc (foreign // {__rustSourceContext = null;})).drvPath == (call helper fullSrc foreign).drvPath;
    }) {} (builtins.attrNames adapters);
  craneCall = h: source: extra:
    h.mkCraneRustPackage ({
        attrs = {
          src = source;
          pname = "recording";
        };
        craneLib = adapterCrane;
        rustPlatform = adapterPkgs.rustPlatform;
      }
      // extra);
  craneAssertions = builtins.foldl' (acc: layer: let
    foreign = {${layer}.src = wrongSrc;};
    same = {${layer}.src = fullSrc;};
  in
    acc
    // {
      ${"fullScopeCrane" + layer + "OverrideRejected"} = fails (craneCall fullBound fullSrc foreign).drvPath;
      ${"subsetCrane" + layer + "OverrideRejected"} = fails (craneCall bound selectedSrc foreign).drvPath;
      ${"fullScopeCrane" + layer + "SameSourcePreserved"} = (craneCall fullBound fullSrc same).drvPath == (craneCall helper fullSrc same).drvPath;
      ${"nullContextCrane" + layer + "Identity"} =
        (craneCall helper fullSrc (foreign // {__rustSourceContext = null;})).drvPath == (craneCall helper fullSrc foreign).drvPath;
    }) {} ["depsOnlyAttrs" "finalAttrs"];
  assertions =
    {
      fullMissingForeignFails = reason "missing-member-manifest" (planner.plan {src = selectedSrc;});
      rootOverlapRejectsBeforeSelectedOrForeignParse = reason "overlapping-member-directories" overlapScoped;
      rootOverlapReaderDoesNotPeek = overlapInputs.members == {} && overlapInputs.additionalInputs == [];
      rootOverlapPureDoesNotForceMemberSet = reason "overlapping-member-directories" (planner.planFromManifests {
        workspace = builtins.fromTOML (builtins.readFile (fixture + "/root-overlap/Cargo.toml"));
        memberDirs = ["members"];
        members = throw "root topology must reject before selecting or intersecting member values";
      });
      rootOverlapDoesNotScanForeignTree = !builtins.any (r: r.code == "local-cargo-config") overlapScoped.reasons;
      rootOverlapChildScopeRejectsBeforeParse = reason "overlapping-member-directories" (planner.plan {
        src = fixture + "/root-overlap";
        memberDirs = ["members/peer"];
      });
      fullScopeCraneDefaultIdentity = (craneCall fullBound fullSrc {}).drvPath == (craneCall helper fullSrc {}).drvPath;
      fullScopeCraneFallbackIgnoresInactiveOverrides =
        (craneCall fullBound fullSrc {
          craneLib = null;
          finalAttrs.src = throw "inactive final attrs must stay lazy";
          depsOnlyAttrs.src = throw "inactive dependency attrs must stay lazy";
          fallbackAttrs.src = fullSrc;
        }).drvPath
        == (craneCall helper fullSrc {
          craneLib = null;
          fallbackAttrs.src = fullSrc;
        }).drvPath;
      fullScopeCraneExplicitForeignSourceNotNormalized = fails (craneCall fullBound wrongSrc {finalAttrs.src = fullSrc;}).drvPath;
      fullScopeRustOpaqueSourceRejected = fails (adapters.rust fullBound fullSrc {build = build "opaque" {};}).drvPath;
      fullScopeCargoOpaqueSourceRejected = fails (adapters.cargo fullBound fullSrc {build = build "opaque" {};}).drvPath;
      unboundRustOpaqueSourcePreserved = (adapters.rust helper fullSrc {build = build "opaque" {};}).drvPath == (build "opaque" {}).drvPath;
      unboundCargoOpaqueSourcePreserved = (adapters.cargo helper fullSrc {build = build "opaque" {};}).drvPath == (build "opaque" {}).drvPath;
      fullScopeRustSuppliedBuildSourceRejected = fails (adapters.rust fullBound fullSrc {build = build "supplied" {src = wrongSrc;};}).drvPath;
      fullScopeCargoSuppliedBuildSourceRejected = fails (adapters.cargo fullBound fullSrc {build = build "supplied" {src = wrongSrc;};}).drvPath;
      fullScopeRustSuppliedBuildIgnoresInactiveOverride =
        (adapters.rust fullBound fullSrc {
          build = build "supplied" {src = fullSrc;};
          buildAttrs.src = wrongSrc;
        }).drvPath
        == (adapters.rust helper fullSrc {build = build "supplied" {src = fullSrc;};}).drvPath;
      fullScopeCargoSuppliedBuildIgnoresInactiveOverride =
        (adapters.cargo fullBound fullSrc {
          build = build "supplied" {src = fullSrc;};
          buildAttrs.src = wrongSrc;
        }).drvPath
        == (adapters.cargo helper fullSrc {build = build "supplied" {src = fullSrc;};}).drvPath;
      fullScopeCraneFallbackOverrideRejected =
        fails
        (craneCall fullBound fullSrc {
          craneLib = null;
          fallbackAttrs.src = wrongSrc;
        }).drvPath;
      subsetCraneFallbackOverrideRejected =
        fails
        (craneCall bound selectedSrc {
          craneLib = null;
          fallbackAttrs.src = wrongSrc;
        }).drvPath;
      fullScopeCraneFallbackSameSourcePreserved =
        (craneCall fullBound fullSrc {
          craneLib = null;
          fallbackAttrs.src = fullSrc;
        }).drvPath
        == (craneCall helper fullSrc {
          craneLib = null;
          fallbackAttrs.src = fullSrc;
        }).drvPath;
      unboundCraneFinalOverridePreserved = toString (craneCall helper fullSrc {finalAttrs.src = wrongSrc;}).src == toString wrongSrc;
      unboundCraneDepsOverridePreserved = toString (craneCall helper fullSrc {depsOnlyAttrs.src = wrongSrc;}).cargoArtifacts.src == toString wrongSrc;
      unboundCraneFallbackOverridePreserved =
        toString
        (craneCall helper fullSrc {
          craneLib = null;
          fallbackAttrs.src = wrongSrc;
        }).src
        == toString wrongSrc;
      fullValid = (planner.plan {src = fullSrc;}).supported;
      scopedSelectedSucceeds = scoped.supported && scoped.plan.members == memberDirs;
      scopedMalformedForeignNotRead =
        (planner.plan {
          src = fixture + "/malformed-foreign";
          inherit memberDirs;
        }).supported;
      pureForeignValueNotRead = (pure {members = manifestMembers // {"members/peer" = throw "outside manifest must not be forced";};}).supported;
      outsideDependencyRejectedBeforeForeignParse = reason "path-outside-source-scope" outside;
      outsideDependencyNotProbed = !builtins.any (r: builtins.elem r.code ["missing-dependency-path" "symlink-dependency-path" "path-package-name-mismatch"]) outside.reasons;
      scopedInsideMissingFails = reason "missing-member-manifest" (planner.plan {
        src = selectedSrc;
        memberDirs = ["members/peer"];
      });
      emptyScopeFails = reason "invalid-source-scope" (pure {memberDirs = [];});
      nullScopeFails = reason "invalid-source-scope" (pure {memberDirs = null;});
      stringScopeFails = reason "invalid-source-scope" (pure {memberDirs = "members/leaf";});
      nonstringScopeFails = reason "invalid-source-scope" (pure {memberDirs = [1];});
      duplicateScopeFails = reason "duplicate-source-scope-member" (pure {memberDirs = ["members/leaf" "members/leaf"];});
      noncanonicalScopeFails = reason "noncanonical-source-scope-member" (pure {memberDirs = ["./members/leaf"];});
      undeclaredScopeFails = reason "undeclared-source-scope-member" (pure {memberDirs = ["members/unknown"];});
      escapeScopeFails = reason "noncanonical-source-scope-member" (pure {memberDirs = ["../outside"];});
      rootGlobStillFails = reason "member-glob" (pure {workspace = root // {workspace = root.workspace // {members = root.workspace.members ++ ["foreign/*"];};};});
      rootNoncanonicalStillFails = reason "member-not-normalized" (pure {workspace = root // {workspace = root.workspace // {members = root.workspace.members ++ ["./foreign"];};};});
      rootOverlapStillFails = reason "overlapping-member-directories" (pure {workspace = root // {workspace = root.workspace // {members = root.workspace.members ++ ["foreign" "foreign/nested"];};};});
      rootPackageStillFails = reason "root-package-filter-unsupported" (pure {workspace = root // {package.name = "root";};});
      rootDotStillFails = reason "root-package-filter-unsupported" (pure {workspace = root // {workspace = root.workspace // {members = root.workspace.members ++ ["."];};};});
      excludesStillFail = reason "workspace-excludes" (pure {workspace = root // {workspace = root.workspace // {exclude = ["foreign"];};};});
      defaultMembersStillFail = reason "workspace-default-members" (pure {workspace = root // {workspace = root.workspace // {default-members = ["members/leaf"];};};});
      symlinkSelectedFails = reason "symlink-source-path" (planner.plan {
        src = fixture + "/symlink";
        inherit memberDirs;
      });
      configSelectedFails = reason "local-cargo-config" (planner.plan {
        src = fixture + "/config";
        inherit memberDirs;
      });
      normalOutsideFails = reason "path-outside-source-scope" (withDependency "dependencies" false);
      buildOutsideFails = reason "path-outside-source-scope" (withDependency "build-dependencies" false);
      devOutsideFails = reason "path-outside-source-scope" (withDependency "dev-dependencies" false);
      optionalOutsideFails = reason "path-outside-source-scope" (withDependency "dependencies" true);
      targetOutsideFails = reason "path-outside-source-scope" (pure {members = manifestMembers // {"members/application" = manifestMembers."members/application" // {target."cfg(any())"."dev-dependencies".peer.path = "../peer";};};});
      unusedRootOutsideConservativeFails = reason "path-outside-source-scope" (pure {workspace = root // {workspace = root.workspace // {dependencies.peer.path = "members/peer";};};});
      inheritedOutsideFails = reason "path-outside-source-scope" (pure {
        workspace = root // {workspace = root.workspace // {dependencies.peer.path = "members/peer";};};
        members = manifestMembers // {"members/application" = manifestMembers."members/application" // {dependencies.peer.workspace = true;};};
      });
      selectedRootBytesEqual = builtins.readFile (selectedSrc + "/Cargo.toml") == builtins.readFile (fullSrc + "/Cargo.toml");
      selectedLockBytesEqual = builtins.readFile (selectedSrc + "/Cargo.lock") == builtins.readFile (fullSrc + "/Cargo.lock");
      readWorkspaceAPI =
        (planner.readWorkspace {
          src = selectedSrc;
          inherit memberDirs;
        }).memberDirs
        == memberDirs;
      boundPlannerAPI = bound.rustPlan {src = selectedSrc;} == scoped;
      boundHelperShape = builtins.attrNames bound == builtins.attrNames helper;
      boundHelperOperations = bound.mergeParts [] == helper.mergeParts [];
      scopeMetadata = scoped.metadata.sourceScope.kind == "closed-selected-workspace" && scoped.metadata.sourceScope.properSubset;
      fullMetadataUnchanged = !(planner.plan {src = fullSrc;}).metadata ? sourceScope;
      allDeclaredMetadata = scoped.metadata.sourceScope.declaredMemberDirs == memberDirs ++ ["members/peer"];
      fullScopeNotPartial = !(fullBound.rustPlan {src = fullSrc;}).metadata.sourceScope.properSubset;
      fullScopeUnionPreserved = (fullBound.mkRustDerivation (fullCtx // appArgs)).drvPath == (helper.mkRustDerivation (fullCtx // appArgs)).drvPath;
      sourceOnlyV1Recipe = builtins.attrNames scopedV1.passthru.rustClosureBaseRecipe == ["projectDir" "sourceDirs" "version"];
      sourceOnlyV2Recipe = builtins.attrNames scopedV2.passthru.rustClosureBaseRecipe == ["parent" "projectDir" "sourceDirs" "version"];
      v1RecipeEqual = scopedV1.passthru.rustClosureBaseRecipe == fullV1.passthru.rustClosureBaseRecipe;
      v2RecipeEqual = scopedV2.passthru.rustClosureBaseRecipe == fullV2.passthru.rustClosureBaseRecipe;
      outsideRecipeCannotAuthorize = fails (bound.mkClosureBase (ctx // {projectDir = "members/peer";})).drvPath;
      scopeConstructorWrongSource = fails (bound.mkClosureBase (ctx // leafArgs // {src = wrongSrc;})).drvPath;
      scopeConsumerWrongSource =
        fails
        (bound.mkRustDerivation (ctx
          // appArgs
          // {
            src = wrongSrc;
            base = scopedV2;
          })).drvPath;
      scopePlannerWrongSource = fails (bound.rustPlan {src = wrongSrc;});
      scopeCompositionWrongSource = fails (bound.mkRustComposition (ctx
        // {
          src = wrongSrc;
          baseMode = "member";
        }));
      scopeCompositionCallerSourceOverride =
        fails
        (composition.mkRustDerivation {
          projectDir = appArgs.projectDir;
          src = wrongSrc;
        }).drvPath;
      scopeContextOverrideFails = fails (bound.mkClosureBase (ctx // leafArgs // {__rustSourceContext = null;}));
      scopeBaseNullRejected = fails (bound.mkRustDerivation (ctx // appArgs)).drvPath;
      scopeFalseRejected = fails (bound.mkRustDerivation (ctx // appArgs // {useWorkspaceDeps = false;})).drvPath;
      scopeSuppliedBuildRejected = fails (bound.mkRustDerivation (ctx // appArgs // {build = mkDrv "outside" {};})).drvPath;
      scopeExplicitNullCompositionRejected =
        fails
        (composition.mkRustDerivation {
          projectDir = appArgs.projectDir;
          base = null;
        }).drvPath;
      explicitIsolationRejected = fails (composition.mkRustDerivation (appArgs // {useWorkspaceDeps = false;})).drvPath;
      unsupportedLegacyModeRejected = fails (bound.mkRustComposition (ctx // {baseMode = "legacy";}));
      legacyExplicitBaseRejected = fails ((bound.mkRustComposition (ctx // {baseMode = "legacy";})).mkRustDerivation (appArgs // {base = fullV2;})).drvPath;
      explicitBaseFalseSupported = builtins.all (mode: let
        chosen = (bound.mkRustComposition (ctx // {baseMode = mode;})).mkRustDerivation (appArgs
          // {
            base = fullV2;
            useWorkspaceDeps = false;
          });
      in
        chosen.drvPath
        == scopedPackage.drvPath
        && chosen.passthru.memberLayer.drvPath == scopedPackage.passthru.memberLayer.drvPath
        && builtins.all (name: chosen.passthru.checks.${name}.drvPath == scopedPackage.passthru.checks.${name}.drvPath) ["fmt" "lint" "test"]) [null "member" "union"];
      scopeUnionRejected = fails ((bound.mkRustComposition (ctx // {baseMode = "union";})).mkRustDerivation appArgs).drvPath;
      scopeOmittedModeRejected = fails ((bound.mkRustComposition ctx).mkRustDerivation appArgs).drvPath;
      scopeIsolatedAdapterRejected = fails (bound.mkCargoWorkspacePackage {src = selectedSrc;});
      scopeTrunkAdapterRejected = fails (bound.mkTrunkProject {src = selectedSrc;});
      scopeCraneAdapterRejected = fails (bound.mkCraneRustPackage {attrs.src = selectedSrc;});
      opaqueBaseRejected = fails (bound.mkRustDerivation (ctx // appArgs // {base = mkDrv "opaque" {};})).drvPath;
      wrongAncestorRejected = fails (bound.mkClosureBase (ctx // middleArgs // {parent = scopedLeaf.overrideAttrs (_: {postBuild = "changed";});})).drvPath;
    }
    // adapterAssertions
    // craneAssertions
    // builtins.mapAttrs (_: evidence: evidence.full == evidence.scoped) equalityEvidence;
  failed = builtins.filter (name: !assertions.${name}) (builtins.attrNames assertions);
in
  assert failed == [] || throw "rust-source-scope failures: ${builtins.concatStringsSep ", " failed}"; {
    assertionCount = builtins.length (builtins.attrNames assertions);
    passed = true;
    inherit equalityEvidence;
  }
