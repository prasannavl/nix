# Shared host/guest recipe evaluation. Every source path is an explicitly
# materialized public store snapshot; no live repository or registry fallback.
# Importing this module constructs recipes only, with the original default
# toolchain and the caller's pinned Nixpkgs/Crane source inputs.
{
  pkgsPath,
  cranePath,
  recipeSupportSrc,
  baselineSrc,
  changedSrc,
  qualificationToolingSrc ? null,
  system ? "x86_64-linux",
}: let
  fail = message: throw "rust-foundation-manager-recipes: ${message}";
  immutablePath = path:
    builtins.isPath path
    && builtins.substring 0 (builtins.stringLength "${builtins.storeDir}/") (toString path) == "${builtins.storeDir}/"
    && builtins.pathExists path;
  pathGuard =
    if
      builtins.all immutablePath ([pkgsPath cranePath recipeSupportSrc baselineSrc changedSrc]
        ++ (
          if qualificationToolingSrc == null
          then []
          else [qualificationToolingSrc]
        ))
    then true
    else fail "all recipe inputs must be existing explicit immutable public store snapshots";
  inputs.crane.mkLib = packages: import cranePath {pkgs = packages;};
  resolver = import (recipeSupportSrc + "/lib/flake/rust-toolchain.nix") {inputs = inputs;};
  regularPkgs = import pkgsPath {
    system = system;
    overlays = [resolver.overlay];
  };
  patchedCargo =
    if qualificationToolingSrc == null
    then regularPkgs.cargo
    else import (qualificationToolingSrc + "/patched-cargo.nix") {pkgs = regularPkgs;};
  qualificationResolver = import (recipeSupportSrc + "/lib/flake/rust-toolchain.nix") {pkgs = qualificationPkgs;};
  # Bind only qualification operations. Avoid rebuilding Cargo's own bootstrap
  # dependency graph through a global Nixpkgs cargo overlay.
  qualificationPkgs =
    regularPkgs
    // {
      cargo = patchedCargo;
      craneLib = regularPkgs.craneLib.overrideScope (_final: _previous: {
        cargo = patchedCargo;
        inherit (regularPkgs) rustc clippy rustfmt;
      });
      rustToolchainFor = qualificationResolver.toolchainFor;
      craneLibFor = qualificationResolver.craneLibFor;
    };
  pkgs =
    if qualificationToolingSrc == null
    then regularPkgs
    else qualificationPkgs;
  lib = pkgs.lib;
  helper = import (recipeSupportSrc + "/lib/flake/pkg-helper.nix");
  agentDir = "pkgs/tools/abird-host-agent";
  managerDir = "pkgs/tools/abird-host-manager";
  memberDirs = [
    "pkgs/examples/hello-rust"
    "pkgs/support/nats-http-bridge"
    agentDir
    managerDir
    "pkgs/tools/nats-wrecking-ball"
  ];
  sameFile = left: right: relative:
    builtins.pathExists (left + "/${relative}")
    == builtins.pathExists (right + "/${relative}")
    && (
      !builtins.pathExists (left + "/${relative}")
      || builtins.readFile (left + "/${relative}") == builtins.readFile (right + "/${relative}")
    );
  sourceGuard = src:
    if !builtins.isPath src
    then fail "sources must be materialized evaluator-visible paths, never derivations/IFD"
    else if !builtins.pathExists (src + "/Cargo.toml") || !builtins.pathExists (src + "/Cargo.lock")
    then fail "each source must retain the full root Cargo manifest and lock"
    else if
      !lib.all (relative: sameFile baselineSrc src relative) [
        "Cargo.toml"
        "Cargo.lock"
        ".cargo/config"
        ".cargo/config.toml"
        "${agentDir}/Cargo.toml"
        "${agentDir}/default.nix"
        "${managerDir}/Cargo.toml"
        "${managerDir}/default.nix"
      ]
    then fail "this source-edit case preserves current manifests, lock, Cargo config and original constructors"
    else true;
  platformGuard =
    if !pkgs.stdenv.hostPlatform.isLinux || pkgs.stdenv.buildPlatform.config != pkgs.stdenv.hostPlatform.config
    then fail "this VM lane requires a native Linux package set"
    else if (pkgs.craneLib or null) == null
    then fail "pass the original package set with its pinned Crane library"
    else true;
  makeCase = src: let
    scoped = helper.forRustSource {inherit src memberDirs;};
    composition = scoped.mkRustComposition {
      inherit pkgs src;
      baseMode = "member";
    };
    packageHelper = scoped // {mkRustDerivation = composition.mkRustDerivation;};
    agent = import (src + "/${agentDir}/default.nix") {
      pkgs = pkgs;
      pkgHelper = packageHelper;
    };
    manager = import (src + "/${managerDir}/default.nix") {
      pkgs = pkgs;
      pkgHelper = packageHelper;
      abirdHostAgent = agent;
    };
    controls = {
      fullFiveMemberScope =
        composition.diagnostics.topology.supported
        && composition.diagnostics.topology.plan.members == builtins.sort builtins.lessThan memberDirs
        && !composition.diagnostics.topology.metadata.sourceScope.properSubset;
      originalManagerClosure = composition.diagnostics.topology.plan.closureDirs.${managerDir} == [agentDir managerDir];
      originalAgentClosure = composition.diagnostics.topology.plan.closureDirs.${agentDir} == [agentDir];
      originalVersion = manager.version == "0.1.0" && agent.version == "0.1.0";
      originalPackagingChecks = !manager.doCheck && !agent.doCheck;
      sameFullLockVendor =
        manager.cargoVendorDir.drvPath
        == agent.cargoVendorDir.drvPath
        && manager.cargoVendorDir.drvPath == manager.passthru.depsBase.cargoVendorDir.drvPath;
    };
  in
    builtins.seq (sourceGuard src) (builtins.deepSeq controls (
      if !lib.all (value: value) (builtins.attrValues controls)
      then fail "original manager/agent composition controls failed"
      else {
        inherit agent manager composition controls;
        lane = {
          build = manager.passthru.memberLayer;
          package = manager;
          mainProgram = manager.meta.mainProgram;
          expectedVersion = "${manager.pname} ${manager.version}\n";
        };
      }
    ));
  baseline = makeCase baselineSrc;
  changed = makeCase changedSrc;
  # Include every actual parent, including context-specific agent bases; a
  # package's direct depsBase alone does not describe its inheritance chain.
  baseChain = base:
    [base]
    ++ lib.optionals (base.passthru ? rustClosureBaseParent) (baseChain base.passthru.rustClosureBaseParent);
  excludedDerivations = lib.concatMap (case:
    [
      case.manager
      case.manager.passthru.memberLayer
      case.agent
      case.agent.passthru.memberLayer
    ]
    ++ baseChain case.manager.passthru.depsBase
    ++ baseChain case.agent.passthru.depsBase) [baseline changed];
  excludedOutputs = lib.unique (map (drv: builtins.unsafeDiscardStringContext drv.outPath) excludedDerivations);
  crateName = dir: (builtins.fromTOML (builtins.readFile (baselineSrc + "/${dir}/Cargo.toml"))).package.name;
  workspaceCrates = map crateName memberDirs;
  # Test expectations, not observations: the original manager member layer
  # inherits the dummy-source dependency base and builds these two real members.
  # A refusal or an external compilation fails this unchanged-warm gate.
  warmFrontier = {
    workspace = builtins.sort builtins.lessThan (map crateName [agentDir managerDir]);
    externalCount = 0;
    totalCount = 2;
  };
  expectedCompilations = {
    unchanged-warm = warmFrontier;
    changed-warm = warmFrontier;
    unchanged-cached = {totalCount = 0;};
    nix-cache-restored = {totalCount = 0;};
  };
  caseGuard =
    if baseline.manager.passthru.memberLayer.drvPath == changed.manager.passthru.memberLayer.drvPath
    then fail "changedSrc must change the actual manager build identity"
    else if baseline.manager.cargoVendorDir.drvPath != changed.manager.cargoVendorDir.drvPath
    then fail "source-only cases must share the original full-lock vendor"
    else true;
in
  builtins.seq pathGuard (builtins.seq platformGuard (builtins.seq caseGuard {
    baseline = baseline.lane;
    changed = changed.lane;
    inherit memberDirs excludedOutputs workspaceCrates expectedCompilations;
    # Handles for reading actual declared inputs only. These producers and all
    # their package/Cargo outputs remain forbidden seed roots.
    seedInputProducers = excludedDerivations;
    qualificationCargo = {
      patched = qualificationToolingSrc != null;
      cargoDrv = pkgs.cargo.drvPath;
      upstreamCommit = pkgs.cargo.depInfoOrderingUpstreamCommit or null;
      productionDefaultChanged = false;
    };
    controls = {
      baseline = baseline.controls;
      changed = changed.controls;
    };
    inputs = {
      vendor = baseline.manager.cargoVendorDir;
      compilerTools = baseline.manager.passthru.actualOperationTools;
      fleetRuntimeInputs = baseline.manager.passthru.fleetRuntimeInputs;
    };
  }))
