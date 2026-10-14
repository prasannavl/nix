# Host-neutral construction controls only; no mock CLI or derivation runs here.
{pkgs}: let
  actual = pkgs.runCommand "fake-semantic-product" {
    outputs = ["out" "dev"];
    meta.mainProgram = "fake-agent";
  } "exit 1";
  foreign = pkgs.runCommand "foreign-semantic-product" {
    meta.mainProgram = "fake-agent";
  } "exit 1";
  expected = {
    schemaVersion = 1;
    versionStdout = "fake-agent 0.1.0\n";
    resourceId = "fixture-resource";
    missingResourceId = "missing-fixture";
    operation = "resource_describe";
    resourceManifest = {
      schema_version = 1;
      resources = [
        {
          id = "fixture-resource";
          data_paths = ["@owned-data@"];
        }
      ];
    };
  };
  acceptance = import ./product-acceptance.nix {
    pkgs = pkgs;
    actualDrv = actual;
    finalDrv = actual;
    expected = expected;
  };
  # A real multi-output fixture exposes drvPath's deep context without running
  # it. Check the serialized file separately from the public identity metadata.
  finalText = acceptance.productSemantic.passthru.finalSpec.text;
  binaryContext = builtins.getContext acceptance.productSemantic.buildCommand;
  selectedOutputContext = builtins.getContext "${actual}";
  actualContextKey = builtins.unsafeDiscardStringContext actual.drvPath;
  expectedWithContext = expected // {versionStdout = "${foreign}/version";};
  contextualAcceptance = import ./product-acceptance.nix {
    pkgs = pkgs;
    actualDrv = actual;
    expected = expectedWithContext;
  };
  same = acceptance.sameActualOutput;
  opaque = {
    drvPath = actual.drvPath;
    outputName = actual.outputName;
    outPath = actual.outPath;
  };
  rejected = final:
    !(builtins.tryEval (builtins.deepSeq
      (import ./product-acceptance.nix {
        pkgs = pkgs;
        actualDrv = actual;
        finalDrv = final;
        expected = expected;
      })
      true)).success;
  controls = {
    actualTriple = same actual actual;
    foreignDrvRejected = !(same actual foreign);
    opaqueOutPathNotDerivation = !(same actual opaque);
    changedDrvPathRejected = !(same actual (actual // {drvPath = foreign.drvPath;}));
    changedOutputRejected = !(same actual (actual // {outputName = "dev";}));
    changedStorePathRejected = !(same actual (actual // {outPath = foreign.outPath;}));
    foreignModuleRejected = rejected foreign;
    opaqueModuleRejected = rejected opaque;
    outputModuleRejected = rejected (actual // {outputName = "dev";});
    selectedProductBound = same acceptance.productSemantic.passthru.actualProduct actual;
    finalProductBound = same acceptance.productSemantic.passthru.finalProduct actual;
    finalSerializationAfterBinding = acceptance.final.derivationPath == actual.drvPath;
    binaryStoreContext = builtins.hasContext acceptance.productSemantic.buildCommand;
    fixtureDrvPathHasDeepContext = builtins.any (entry: entry.allOutputs or false) (builtins.attrValues (builtins.getContext actual.drvPath));
    publicIdentityContextUnchanged = builtins.getContext acceptance.final.derivationPath == builtins.getContext actual.drvPath;
    serializedIdentityBytesPreserved = builtins.fromJSON finalText == acceptance.final;
    serializedIdentityContextFree = builtins.getContext finalText == {};
    binarySelectedOutContext =
      (binaryContext.${actualContextKey} or {})
      == selectedOutputContext.${actualContextKey}
      && (binaryContext.${actualContextKey}.outputs or []) == ["out"];
    binaryNoDeepContext = builtins.all (entry: !(entry.allOutputs or false)) (builtins.attrValues binaryContext);
    expectedSerializationKeepsContext =
      builtins.getContext contextualAcceptance.productSemantic.passthru.expectedSpec.text
      == builtins.getContext (builtins.toJSON expectedWithContext);
    explicitlyUnexecuted = acceptance.runtimeAcceptance == "not_executed";
    producerStillUnqualified = !acceptance.productSemantic.passthru.producerQualified;
    moduleAssertionsForced = acceptance.assertionsCount == 3;
  };
in
  assert builtins.all (value: value) (builtins.attrValues controls);
    builtins.deepSeq controls {
      controls = controls;
      assertionsCount = builtins.length (builtins.attrNames controls);
      runtimeAcceptance = "not_executed";
    }
