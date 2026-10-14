# Offline, no-IFD tests. Synthetic metadata is never native evidence.
{
  pkgs,
  sources,
}: let
  lib = pkgs.lib;
  qualification = import ./invalidation.nix {inherit pkgs sources;};
  target = qualification.acceptanceTargets.memberInvalidation;
  script = target.buildCommand;
  scriptContext = builtins.getContext script;
  names = ["baseline" "lockEdit" "manifestEdit" "rustEdit"];
  routes = ["baseline" "member"];
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  # Force precisely the target construction boundary, not a diagnostic flag.
  rejects = supplied:
    fails
    (import ./invalidation.nix {
      pkgs = pkgs;
      sources = supplied;
    }).acceptanceTargets.memberInvalidation.drvPath;
  compare = qualification.comparisonControls.stdoutRelationships;
  synthetic = {
    baseline = "synthetic-original";
    rustEdit = "synthetic-edited";
    manifestEdit = "synthetic-original";
    lockEdit = "synthetic-original";
  };
  assertions = {
    actualConstructorControlsForced =
      builtins.all (value: value) (builtins.attrValues qualification.controls)
      && builtins.isString target.drvPath;
    exactlyOneExplicitTarget = builtins.attrNames qualification.acceptanceTargets == ["memberInvalidation"];
    missingUnexpectedAndNonAttrSourcesFail =
      rejects (builtins.removeAttrs sources ["lockEdit"])
      && rejects (sources // {unexpected = sources.baseline;})
      && rejects [];
    nonPathAndDerivationSourcesFail =
      rejects (sources // {rustEdit = toString sources.rustEdit;})
      && rejects (sources // {rustEdit = target;});
    identicalRustSourceFailsTargetConstruction = rejects (sources // {rustEdit = sources.baseline;});
    identicalManifestSourceFailsTargetConstruction = rejects (sources // {manifestEdit = sources.baseline;});
    identicalLockSourceFailsTargetConstruction = rejects (sources // {lockEdit = sources.baseline;});
    wrongSemanticSourceFailsTargetConstruction = rejects (sources // {rustEdit = sources.manifestEdit;});
    swappedManifestLockSourcesFailTargetConstruction = rejects (sources
      // {
        manifestEdit = sources.lockEdit;
        lockEdit = sources.manifestEdit;
      });
    expectedStoreContextsSurviveInScript = builtins.all (name: let
      input = qualification.expectedInputs.${name};
      context = qualification.expectedContexts.${name};
    in
      lib.hasPrefix "/nix/store/" input
      && builtins.attrNames context != []
      && builtins.all (path:
        (context.${path}.path or false)
        && (scriptContext.${path} or null) == context.${path}) (builtins.attrNames context)
      && lib.hasInfix (lib.escapeShellArg (builtins.unsafeDiscardStringContext input)) script
      && !lib.hasInfix "${toString sources.${name}}/expected-output.txt" script)
    names;
    onlyFourMemberBinariesReferenced = builtins.all (name: let
      q = import ./default.nix {
        pkgs = pkgs;
        src = sources.${name};
      };
    in
      lib.hasInfix
      (lib.escapeShellArg (builtins.unsafeDiscardStringContext (lib.getExe q.consumers.member)))
      script
      && builtins.attrNames q.consumers == routes
      && !(builtins.hasAttr
        (builtins.unsafeDiscardStringContext qualification.matrix.${name}.routes.baseline.final.derivationPath)
        scriptContext))
    names;
    metadataDoesNotRealizeCheckOutputs = builtins.all (name:
      builtins.all (route:
        builtins.all (check: let
          id = qualification.matrix.${name}.routes.${route}.checks.${check};
        in
          !(builtins.hasAttr (builtins.unsafeDiscardStringContext id.derivationPath) scriptContext))
        ["fmt" "lint" "test"])
      routes)
    names;
    identityRowsNotCoercedToPaths = builtins.all (name:
      builtins.all (route: let
        row = qualification.matrix.${name}.routes.${route}.final;
      in
        builtins.isAttrs row
        && builtins.attrNames row == ["derivationPath" "output" "storePath"]
        && row.output == "out")
      routes)
    names;
    contextTuplesMatchActualMemberIdentities = builtins.all (name: let
      context = qualification.contexts.${name};
      route = qualification.matrix.${name}.routes.member;
    in
      context.projectDir
      == "members/app"
      && context.base.output == qualification.matrix.${name}.bases."members/app"
      && context.memberLayer.input == context.base.output
      && context.memberLayer.output == route.memberLayer
      && context.final.input == route.memberLayer
      && context.final.output == route.final)
    names;
    runtimeBoundAndStrictShell =
      lib.hasInfix "set -Eeuo pipefail" script
      && lib.hasInfix "timeout 10 \"$binary\"" script
      && lib.hasInfix "[[ \"$comparison_status\" -eq 1 ]]" script;
    syntheticComparisonPositive = compare synthetic;
    syntheticComparisonRejectsTampering = builtins.all (value: !compare value) [
      (synthetic // {rustEdit = synthetic.baseline;})
      (synthetic // {manifestEdit = synthetic.rustEdit;})
      (synthetic // {lockEdit = synthetic.rustEdit;})
      (synthetic // {rustEdit = null;})
      (synthetic // {unexpected = "synthetic";})
      (builtins.removeAttrs synthetic ["baseline"])
      []
    ];
    producerAndFreshnessRemainUnproved =
      !qualification.diagnostics.producer.qualified
      && qualification.diagnostics.producer.decision == "not_proven"
      && qualification.diagnostics.cargoFreshness == "not_observed"
      && qualification.diagnostics.resolvedUnitInventory == "not_observed";
  };
  failed = builtins.filter (name: !assertions.${name}) (builtins.attrNames assertions);
in
  assert failed == [] || throw "rust-g4-invalidation-eval failures: ${lib.concatStringsSep ", " failed}"; {
    inherit assertions;
    assertionCount = builtins.length (builtins.attrNames assertions);
    constructorControlCount = builtins.length (builtins.attrNames qualification.controls);
    passed = true;
    evidence = "offline constructor observations and synthetic negative controls; no native execution";
    producer = qualification.diagnostics.producer;
  }
