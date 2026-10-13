# Pvl-specific construction observations; optional acceptance stays unexecuted.
# Do not port this identity file to another repository or register root checks.
# src must be the caller-owned immutable five-member Cargo projection; this is
# NOT a generator-valid M mirror (its HEAD predates revision-owned support).
{
  pkgs,
  src,
  enableProductSemantic ? false,
}: let
  helper = import ../../../lib/flake/pkg-helper.nix;
  member = "pkgs/tools/abird-host-agent";
  memberDirs = [
    "pkgs/examples/hello-rust"
    "pkgs/support/nats-http-bridge"
    member
    "pkgs/tools/abird-host-manager"
    "pkgs/tools/nats-wrecking-ball"
  ];
  scoped = helper.forRustSource {inherit src memberDirs;};
  composition = scoped.mkRustComposition {
    inherit pkgs src;
    baseMode = "member";
  };
  originalConstructor = import (src + "/${member}/default.nix");
  originalArgs = originalConstructor {
    pkgs = pkgs;
    pkgHelper.mkRustDerivation = args: args;
  };
  product = originalConstructor {
    pkgs = pkgs;
    pkgHelper = scoped // {mkRustDerivation = composition.mkRustDerivation;};
  };
  # Same original constructor/source/helper, without opt-in admission. Metadata
  # comparison only: not an additional selected native target.
  originalDefault = originalConstructor {
    pkgs = pkgs;
    pkgHelper = scoped // {mkRustDerivation = args: scoped.mkRustDerivation (args // {src = src;});};
  };
  identity = drv: {
    derivationPath = drv.drvPath;
    output = drv.outputName;
    storePath = drv.outPath;
  };
  observe = drv: {
    final = identity drv;
    memberLayer = identity drv.passthru.memberLayer;
    checks = builtins.mapAttrs (_: identity) drv.passthru.checks;
    operationTools = builtins.mapAttrs (_: identity) drv.passthru.actualOperationTools;
    pname = drv.pname;
    version = drv.version;
    doCheck = drv.doCheck;
    nativeCheckInputs = map identity (drv.nativeCheckInputs or []);
    cargoVendorDir = identity drv.cargoVendorDir;
    source = identity drv.src;
    rustToolchainId = drv.passthru.rustToolchainId;
  };
  # Expectations belong to this Pvl product owner, not the generic runner.
  semanticAcceptance = import ./product-acceptance.nix {
    pkgs = pkgs;
    actualDrv = product;
    finalDrv = product;
    expected = {
      schemaVersion = 1;
      versionStdout = "abird-host-agent 0.1.0\n";
      resourceId = "qualification";
      missingResourceId = "does-not-exist";
      operation = "resource_describe";
      resourceManifest = {
        schema_version = 1;
        resources = [
          {
            id = "qualification";
            data_paths = ["@owned-data@"];
          }
        ];
      };
    };
  };
  base = product.passthru.depsBase;
  recipe = base.passthru.rustClosureBaseRecipe;
  controls = {
    actualFiveMembers = composition.diagnostics.topology.plan.members == builtins.sort builtins.lessThan memberDirs;
    supportedDeclaredTopology = composition.diagnostics.topology.supported;
    singletonAgent = composition.diagnostics.topology.plan.closureDirs.${member} == [member];
    managerClosure = composition.diagnostics.topology.plan.closureDirs."pkgs/tools/abird-host-manager" == [member "pkgs/tools/abird-host-manager"];
    fullSourceScope = !composition.diagnostics.topology.metadata.sourceScope.properSubset;
    originalVersion = product.version == "0.1.0" && originalDefault.version == product.version;
    originalDoCheckFalse = !product.doCheck && !originalDefault.doCheck;
    originalRsyncCheckInput =
      map identity originalArgs.nativeCheckInputs
      == [(identity pkgs.rsync)]
      && builtins.elem (identity pkgs.rsync) (map identity product.passthru.checks.test.nativeBuildInputs);
    admittedSingletonBase =
      recipe.sourceDirs
      == [member]
      && !(recipe ? parent)
      && builtins.elem (identity pkgs.rsync) (map identity base.nativeBuildInputs);
    sameFullLockVendor = (identity product.cargoVendorDir) == (identity base.cargoVendorDir);
    sameOperationTools = (observe product).operationTools == (observe originalDefault).operationTools;
  };
in
  assert builtins.all (value: value) (builtins.attrValues controls);
    builtins.deepSeq controls {
      actualTargetDrvPath = product.drvPath;
      targetOutputName = product.outputName;
      selectedTargetCount = 1;
      selectedTarget = "original abird-host-agent constructor, scoped member G4";
      constructorControlCount = builtins.length (builtins.attrNames controls);
      controls = controls;
      product = observe product;
      originalDefault =
        (observe originalDefault)
        // {
          sharedDepsBase = identity originalDefault.passthru.sharedDepsBase;
          selectedNativeTarget = false;
        };
      depsBase = identity base;
      baseRecipe = {
        inherit (recipe) projectDir sourceDirs;
        parent = recipe.parent or null;
        declaredNativeCheckInputs = map identity originalArgs.nativeCheckInputs;
        actualBaseNativeBuildInputs = map identity base.nativeBuildInputs;
        actualBaseBuildInputs = map identity (base.buildInputs or []);
      };
      compilerRoots = builtins.mapAttrs (_: identity) product.passthru.actualOperationTools;
      rsync = identity pkgs.rsync;
      diagnostics = {
        topology = composition.diagnostics;
        sourceKind = "immutable-Cargo-product-source-projection-not-M-mirror";
        originalConstructorPreserved = true;
        runtimeAcceptance = "not_executed";
        cargoMode = "release/offline; not locked";
        producer = {
          qualified = false;
          decision = "not_proven";
        };
        productG4Accepted = false;
        defaultAdoption = false;
        costQualification24Members = "not_proven";
      };
    }
    // pkgs.lib.optionalAttrs enableProductSemantic {
      acceptanceTargets.productSemantic = semanticAcceptance.productSemantic;
      acceptanceBindings = {
        controls = semanticAcceptance.controls;
        assertionsCount = semanticAcceptance.assertionsCount;
        final = semanticAcceptance.final;
        runtimeAcceptance = "not_executed";
      };
    }
