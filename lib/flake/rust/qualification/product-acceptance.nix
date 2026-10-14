# Explicit construction only; realization needs separate native admission.
# Receive actual derivations from the owner, never re-import its constructor.
{
  pkgs,
  actualDrv,
  finalDrv ? actualDrv,
  expected,
}: let
  lib = pkgs.lib;
  identity = drv: {
    derivationPath = drv.drvPath;
    output = drv.outputName;
    storePath = drv.outPath;
  };
  sameActualOutput = actual: final:
    lib.isDerivation actual
    && lib.isDerivation final
    && actual.drvPath == final.drvPath
    && actual.outputName == final.outputName
    && actual.outPath == final.outPath;
  controls = {
    actualDerivationBinding = sameActualOutput actualDrv finalDrv;
    supportedOutput = actualDrv.outputName == "out";
    ownedMainProgram =
      builtins.isString actualDrv.meta.mainProgram
      && actualDrv.meta.mainProgram != ""
      && builtins.match "[a-zA-Z0-9_-]+" actualDrv.meta.mainProgram != null;
  };
  final = identity finalDrv;
  # The outer assertions bind this identity to the actual selected derivation.
  # JSON is descriptive data, not authentication or a request to realize the
  # deep drvPath context (all outputs of its entire derivation closure). Strip
  # context ONLY at this serialization boundary; keep public final unchanged.
  # The binary below retains the actual selected-output dependency. Expected
  # specification contexts are not stripped.
  finalFile = pkgs.writeText "product-semantic-final.json" (builtins.unsafeDiscardStringContext (builtins.toJSON final));
  expectedFile = pkgs.writeText "product-semantic-expected.json" (builtins.toJSON expected);
  # Interpolation retains the actual selected output's store context.
  binary = "${actualDrv}/bin/${actualDrv.meta.mainProgram}";
  productSemantic =
    pkgs.runCommand "product-semantic-acceptance" {
      nativeBuildInputs = [pkgs.python3];
      passthru = {
        actualProduct = actualDrv;
        finalProduct = finalDrv;
        expectedSpec = expectedFile;
        finalSpec = finalFile;
        finalIdentity = final;
        runtimeAcceptance = "not_executed";
        producerQualified = false;
      };
    } ''
      set -Eeuo pipefail
      # Source copies are explicit store inputs, not adjacent evaluation scratch.
      mkdir runner
      cp ${./product_semantic.py} runner/product_semantic.py
      cp ${./fixture.py} runner/fixture.py
      ${pkgs.python3}/bin/python3 -B runner/product_semantic.py \
        --binary ${lib.escapeShellArg binary} \
        --final ${finalFile} --expected ${expectedFile} \
        --output "$PWD/observations" --output-root "$PWD"
      mv observations "$out"
    '';
in
  assert builtins.all (value: value) (builtins.attrValues controls);
    builtins.deepSeq controls {
      inherit controls productSemantic sameActualOutput;
      assertionsCount = builtins.length (builtins.attrNames controls);
      final = final;
      runtimeAcceptance = "not_executed";
    }
