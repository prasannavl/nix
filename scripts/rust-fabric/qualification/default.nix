# Explicit fixture targets only. No root registration or automatic adoption.
{
  pkgs,
  src,
}: let
  helper = import ../../../lib/flake/pkg-helper.nix;
  fail = message: throw "rust-g4-qualification: ${message}";
  sourceGuard =
    if !builtins.isPath src
    then fail "src must be a materialized evaluator-visible path, not a source derivation"
    else if !builtins.pathExists (src + "/Cargo.toml")
    then fail "src must contain the materialized Cargo workspace"
    else true;
  memberDirs = map (name: "members/${name}") [
    "leaf"
    "branch"
    "app"
    "build-helper"
    "macro"
    "dev-helper"
    "peer"
  ];
  topology = helper.rustPlan {src = src;};
  fixtureGuard =
    if !topology.supported
    then fail "fixture must have supported declared source closures"
    else if topology.plan.members != builtins.sort builtins.lessThan memberDirs
    then fail "expected exactly the seven qualification fixture members"
    else true;
  recipe = dir: {
    projectDir = dir;
    pname = (builtins.fromTOML (builtins.readFile (src + "/${dir}/Cargo.toml"))).package.name;
    version = "0.1.0";
    deps = builtins.filter (dep: dep != dir) topology.plan.closureDirs.${dir};
    meta = {
      description = "G4 qualification fixture consumer";
      mainProgram = "g4-app";
    };
  };
  appArgs = recipe "members/app";
  context = {inherit pkgs src;};
  compose = mode: helper.mkRustComposition (context // {baseMode = mode;});
  memberFactory = compose "member";
  consumers = {
    baseline = helper.mkRustDerivation (context // appArgs);
    member = memberFactory.mkRustDerivation appArgs;
  };
  baseHandles = builtins.listToAttrs (map (dir: {
      name = dir;
      value = memberFactory.baseFor dir;
    })
    topology.plan.members);
  parents = memberFactory.diagnostics.parents;
  acceptance = import ./accept.nix {
    inherit pkgs src;
    qualification = {inherit baseHandles consumers memberDirs;};
  };
  identity = drv: {
    derivationPath = drv.drvPath;
    output = drv.outputName;
    storePath = drv.outPath;
  };
  parentHandle = dir: baseHandles.${dir}.passthru.rustClosureBaseParent or null;
  archivePath = drv: "${drv}/target.tar.zst";
  compiledInputs =
    builtins.mapAttrs (dir: base: let
      parent = parentHandle dir;
    in {
      handle = identity base;
      source = toString base.src;
      cargoLock = base.cargoLock;
      vendor = identity base.cargoVendorDir;
      stdenv = identity base.stdenv;
      vendorStdenv = identity base.cargoVendorDir.stdenv;
      recipe = base.passthru.rustClosureBaseRecipe;
      selectedParent = parents.${dir};
      actualParent =
        if parent == null
        then null
        else identity parent;
      cargoArtifacts =
        if base.cargoArtifacts == null
        then null
        else identity base.cargoArtifacts;
      archive = {
        relativePath = "target.tar.zst";
        path = archivePath base;
        previousRelativePath = "target.tar.zst.prev";
        previousRootObservation =
          if parent == null
          then null
          else archivePath parent;
      };
    })
    baseHandles;
  buildTargets =
    consumers
    // builtins.listToAttrs (map (name: {
      name = "${name}-test";
      value = consumers.${name}.passthru.checks.test;
    }) ["baseline" "member"])
    // builtins.listToAttrs (map (dir: {
        name = "base-${builtins.baseNameOf dir}";
        value = baseHandles.${dir};
      })
      topology.plan.members);
in
  builtins.seq sourceGuard (builtins.seq fixtureGuard {
    inherit baseHandles buildTargets compiledInputs consumers memberDirs parents;
    acceptanceTargets = acceptance.acceptanceTargets;
    archiveObservationValid = acceptance.validateArchiveMetadata;
    diagnostics = {
      kind = "declared-source-closure-construction";
      recipeObservationVersion = 1;
      topology = topology;
      producer = {
        qualified = false;
        decision = "not_proven";
      };
      nativeAcceptance = "deferred-explicit-approval-required";
      cargoFreshness = "not_observed";
      resolvedUnitInventory = "not_observed";
    };
  })
