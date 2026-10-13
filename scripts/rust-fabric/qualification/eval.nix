# Offline, no-IFD constructor checks. No materializers or native execution here.
{
  pkgs,
  src,
  variants ? {},
}: let
  helper = import ../../../lib/flake/pkg-helper.nix;
  qualification = import ./default.nix {inherit pkgs src;};
  lib = pkgs.lib;
  identity = drv: {
    derivationPath = drv.drvPath;
    output = drv.outputName;
    storePath = drv.outPath;
  };
  same = a: b: identity a == identity b;
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  context = {inherit pkgs src;};
  topology = qualification.diagnostics.topology;
  memberDirs = topology.plan.members;
  app = "members/app";
  recipe = dir: {
    projectDir = dir;
    pname = (builtins.fromTOML (builtins.readFile (src + "/${dir}/Cargo.toml"))).package.name;
    deps = builtins.filter (dep: dep != dir) topology.plan.closureDirs.${dir};
    meta = {
      description = "G4 qualification fixture consumer";
      mainProgram = "g4-app";
    };
  };
  appArgs = recipe app;
  compose = mode: helper.mkRustComposition (context // {baseMode = mode;});
  direct = extra: helper.mkRustDerivation (context // appArgs // extra);
  baseline = qualification.consumers.baseline;
  member = qualification.consumers.member;
  # The direct isolated helper remains supported, but is not a native route.
  isolated = direct {useWorkspaceDeps = false;};
  baseHandles = qualification.baseHandles;
  parentHandle = dir: baseHandles.${dir}.passthru.rustClosureBaseParent or null;
  all = predicate: builtins.all predicate memberDirs;
  # Observe actual handles, not JSON-rendered derivations or certificates.
  consumerIdentity = pkg: {
    final = identity pkg;
    memberLayer =
      if pkg.passthru ? memberLayer
      then identity pkg.passthru.memberLayer
      else null;
    checks = builtins.mapAttrs (_: identity) (builtins.removeAttrs pkg.passthru.checks ["build"]);
  };
  compatibility = {
    baseline = consumerIdentity baseline;
    explicitNull = consumerIdentity (direct {base = null;});
    omitted = consumerIdentity ((helper.mkRustComposition context).mkRustDerivation appArgs);
    nullMode = consumerIdentity ((compose null).mkRustDerivation appArgs);
    union = consumerIdentity ((compose "union").mkRustDerivation appArgs);
  };
  scoped = helper.forRustSource {inherit src memberDirs;};
  scopedMember = (scoped.mkRustComposition (context // {baseMode = "member";})).mkRustDerivation appArgs;
  partial = helper.forRustSource {
    src = src;
    memberDirs = topology.plan.closureDirs.${app};
  };
  partialFactory = partial.mkRustComposition (context // {baseMode = "member";});
  # Materialized variants are supplied by the fixture lane, not generated here.
  observe = source: let
    q = import ./default.nix {
      pkgs = pkgs;
      src = source;
    };
    plan = q.diagnostics.topology.plan;
    factory = helper.mkRustComposition {
      pkgs = pkgs;
      src = source;
      baseMode = "member";
    };
    packages = builtins.listToAttrs (map (dir: {
        name = dir;
        value = factory.mkRustDerivation {
          projectDir = dir;
          pname = (builtins.fromTOML (builtins.readFile (source + "/${dir}/Cargo.toml"))).package.name;
          deps = builtins.filter (dep: dep != dir) plan.closureDirs.${dir};
        };
      })
      memberDirs);
  in {
    bases = builtins.mapAttrs (_: identity) q.baseHandles;
    vendors = builtins.mapAttrs (_: base: identity base.cargoVendorDir) q.baseHandles;
    locks = builtins.mapAttrs (_: base: toString base.cargoLock) q.baseHandles;
    consumers = builtins.mapAttrs (_: consumerIdentity) packages;
    routes = builtins.mapAttrs (_: consumerIdentity) q.consumers;
  };
  original = observe src;
  variantTable = builtins.mapAttrs (_: observe) variants;
  affected = builtins.filter (dir: builtins.elem "members/leaf" topology.plan.closureDirs.${dir}) memberDirs;
  peer = "members/peer";
  unchanged = field: table: dirs:
    builtins.all (dir: table.${field}.${dir} == original.${field}.${dir}) dirs;
  changed = field: table: dirs:
    builtins.all (dir: table.${field}.${dir} != original.${field}.${dir}) dirs;
  consumerPathsChanged = table: dir: let
    before = original.consumers.${dir};
    after = table.consumers.${dir};
  in
    before.final
    != after.final
    && before.memberLayer != after.memberLayer
    && builtins.all (name: before.checks.${name} != after.checks.${name}) ["fmt" "lint" "test"];
  archive = "/nix/store/fixture-root/target.tar.zst";
  parentArchive = "/nix/store/fixture-parent/target.tar.zst";
  metadata = {
    archiveExists = true;
    archiveBytes = 1;
    entries = ["./release/.fingerprint/g4-leaf/hash.json"];
    chain = [archive];
  };
  validate = extra: qualification.archiveObservationValid (metadata // extra);
  # Force the semantic regular-file guard before this comparison-only import.
  expectedInput = builtins.seq semanticScript "${src + "/expected-output.txt"}";
  expectedContext = builtins.getContext expectedInput;
  semanticScript = qualification.acceptanceTargets.semantic.buildCommand;
  semanticContext = builtins.getContext semanticScript;
  assertions =
    {
      materializedSevenMemberSource =
        builtins.length memberDirs
        == 7
        && fails (import ./default.nix {
          pkgs = pkgs;
          src = toString src;
        })
        && fails (import ./default.nix {
          pkgs = pkgs;
          src = baseline;
        });
      roleClosureIncludesAllAppDependencies =
        topology.plan.closureDirs.${app}
        == builtins.sort builtins.lessThan [
          "members/app"
          "members/branch"
          "members/build-helper"
          "members/dev-helper"
          "members/leaf"
          "members/macro"
        ];
      baselineNullOmittedUnionIdentity = builtins.all (name:
        compatibility.${name} == compatibility.baseline)
      ["explicitNull" "omitted" "nullMode" "union"];
      rejectedMode =
        fails (compose "legacy")
        && fails ((compose "legacy").mkRustDerivation appArgs).drvPath;
      directIsolatedHelperSupported =
        builtins.isString isolated.drvPath
        && isolated.cargoArtifacts != null
        && !(isolated.passthru ? memberLayer)
        && !(isolated.passthru ? sharedDepsBase)
        && !(isolated.passthru ? depsBase);
      memberUsesActualBaseAndLayer =
        same member.passthru.depsBase baseHandles.${app}
        && same member.passthru.memberLayer.cargoArtifacts baseHandles.${app}
        && same member.cargoArtifacts member.passthru.memberLayer;
      allParentHandlesMatchPlanner = all (dir: let
        planned = qualification.parents.${dir};
        actual = parentHandle dir;
      in
        if planned == null
        then actual == null && baseHandles.${dir}.cargoArtifacts == null
        else
          same actual baseHandles.${planned}
          && same baseHandles.${dir}.cargoArtifacts actual);
      strictParentsAndRecipes = all (dir: let
        parent = qualification.parents.${dir};
        recipe = baseHandles.${dir}.passthru.rustClosureBaseRecipe;
      in
        if parent == null
        then recipe.version == 1
        else
          recipe.version
          == 2
          && builtins.elem parent topology.plan.parentCandidates.${dir}
          && builtins.length topology.plan.closureDirs.${parent}
          < builtins.length topology.plan.closureDirs.${dir});
      chainedRecipeUsesCranePrimitive = all (dir:
        if qualification.parents.${dir} == null
        then baseHandles.${dir}.cargoArtifacts == null
        else
          baseHandles.${dir}.CRANE_BUILD_DEPS_ONLY
          == 1
          && lib.hasInfix "cargoWithProfile check --offline --workspace --all-targets"
          baseHandles.${dir}.buildPhase);
      oneFullLockAndVendor =
        all (dir:
          same baseHandles.${dir}.cargoVendorDir baseHandles.${app}.cargoVendorDir
          && baseHandles.${dir}.cargoLock == baseHandles.${app}.cargoLock)
        && same member.cargoVendorDir baseHandles.${app}.cargoVendorDir
        && member.cargoLock == baseHandles.${app}.cargoLock;
      actualConsumerToolsObserved = builtins.all (name:
        toString member.passthru.actualOperationTools.${name}
        == toString baseline.passthru.actualOperationTools.${name})
      ["cargo" "rustc" "clippy" "rustfmt"];
      scopedFullSourceIdentity = same scopedMember member;
      scopedSubsetMemberIdentity = same (partialFactory.mkRustDerivation appArgs) member;
      scopedRejectsPolicyEscapes = builtins.all (value: fails value) [
        (partialFactory.mkRustDerivation (appArgs // {base = null;})).drvPath
        ((partial.mkRustComposition (context // {baseMode = "union";})).mkRustDerivation appArgs).drvPath
        (partialFactory.mkRustDerivation (appArgs // {useWorkspaceDeps = false;})).drvPath
      ];
      effectiveSourceBindingRejectsBroadenedSource =
        fails
        (scoped.mkRustDerivation (context // appArgs // {buildAttrs.src = src + "/members";})).drvPath;
      checkTargetsAreActualConsumers =
        builtins.attrNames qualification.consumers
        == ["baseline" "member"]
        && builtins.all (route:
          same qualification.buildTargets."${route}-test" qualification.consumers.${route}.passthru.checks.test)
        ["baseline" "member"];
      semanticExpectedInputIsStoreDependency =
        lib.hasPrefix "/nix/store/" expectedInput
        && builtins.attrNames expectedContext != []
        && builtins.all (path:
          (expectedContext.${path}.path or false)
          && (semanticContext.${path} or null) == expectedContext.${path})
        (builtins.attrNames expectedContext)
        && lib.hasInfix
        "cmp ${lib.escapeShellArg (builtins.unsafeDiscardStringContext expectedInput)}"
        semanticScript
        && !lib.hasInfix "${toString src}/expected-output.txt" semanticScript;
      archiveMetadataPositive =
        validate {}
        && validate {entries = metadata.entries ++ ["./release/database/secrets-helper/no-key.txt"];}
        && validate {
          selectedParentArchive = parentArchive;
          previousArchive = parentArchive;
          previousIsSymlink = true;
          chain = [archive parentArchive];
        };
      archiveMetadataRejectsBadData = builtins.all (extra: !validate extra) [
        {archiveExists = false;}
        {archiveBytes = 0;}
        {entries = [];}
        {entries = ["../.fingerprint/hash.json"];}
        {entries = ["/release/.fingerprint/hash.json"];}
        {entries = ["./release/deps/libg4_leaf.rlib"];}
        {entries = metadata.entries ++ ["./data/secrets/probe.key"];}
        {entries = metadata.entries ++ ["./release/data/secrets/probe"];}
        {entries = metadata.entries ++ ["./release/data/./secrets/probe"];}
        {entries = metadata.entries ++ ["./release/data//secrets/probe"];}
        {entries = metadata.entries ++ ["./release/.git/config"];}
        {entries = metadata.entries ++ ["./release/credential.key/output"];}
        {entries = metadata.entries ++ ["./release/credential.key"];}
        {entries = metadata.entries ++ ["./release/back\\slash"];}
        {entries = metadata.entries ++ ["./release/new\nline"];}
        {entries = metadata.entries ++ ["./release/tab\tname"];}
        {entries = metadata.entries ++ ["./release/return\rname"];}
        {entries = metadata.entries ++ ["./release/non-ascii-é"];}
        {chain = [archive archive];}
        {chain = builtins.genList (_: archive) 65;}
        {
          previousArchive = parentArchive;
          previousIsSymlink = true;
        }
        {
          selectedParentArchive = parentArchive;
          previousArchive = archive;
          previousIsSymlink = true;
        }
      ];
      qualificationIsNeverInferred =
        !qualification.diagnostics.producer.qualified
        && qualification.diagnostics.producer.decision == "not_proven";
    }
    // lib.optionalAttrs (variants ? rustEdit) {
      rustEditBaseAndVendorInvariant =
        unchanged "bases" variantTable.rustEdit memberDirs
        && unchanged "vendors" variantTable.rustEdit memberDirs;
      rustEditAffectedConsumersChange =
        builtins.all (consumerPathsChanged variantTable.rustEdit) affected
        && builtins.all (route: variantTable.rustEdit.routes.${route} != original.routes.${route})
        ["baseline" "member"];
      rustEditPeerInvariant = unchanged "consumers" variantTable.rustEdit [peer];
    }
    // lib.optionalAttrs (variants ? manifestEdit) {
      manifestEditClosureLocality =
        changed "bases" variantTable.manifestEdit affected
        && unchanged "bases" variantTable.manifestEdit [peer];
      manifestEditVendorInvariant = unchanged "vendors" variantTable.manifestEdit memberDirs;
    }
    // lib.optionalAttrs (variants ? lockEdit) {
      lockEditGlobalBaseInvalidation =
        changed "locks" variantTable.lockEdit memberDirs
        && changed "bases" variantTable.lockEdit memberDirs;
      lockCommentParsedVendorInvariant = unchanged "vendors" variantTable.lockEdit memberDirs;
    };
  failed = builtins.filter (name: !assertions.${name}) (builtins.attrNames assertions);
in
  assert builtins.all (name: builtins.elem name ["rustEdit" "manifestEdit" "lockEdit"])
  (builtins.attrNames variants);
  assert failed == [] || throw "rust-g4-qualification failures: ${lib.concatStringsSep ", " failed}"; {
    inherit assertions compatibility variantTable;
    assertionCount = builtins.length (builtins.attrNames assertions);
    passed = true;
    table = original;
    compiledInputs = qualification.compiledInputs;
    producer = qualification.diagnostics.producer;
    identityTrace = {
      baselineNullCurrentDifferences = builtins.filter (name:
        compatibility.baseline.${name} != compatibility.explicitNull.${name})
      (builtins.attrNames compatibility.baseline);
      historicalComparison = "not-supplied; current-constructor compatibility only";
      lockComment = "all lock/base paths change; Crane parsed vendor stays equal; no resolver proof";
      sourceEdit = "filtered source projection locality, not Cargo freshness";
    };
  }
