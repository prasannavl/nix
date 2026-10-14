# Explicit candidate inventory from original evaluated recipes. No output of a
# tested producer is seeded, and cargoArtifacts is never an input selector.
# This does not certify closure completeness: independent guest absence and
# offline builds remain the gates. Importing selects handles; realization of
# allowed tool/vendor/source outputs is separately owned by Main.
{
  producers,
  excludedOutputs,
  extraInputs ? [],
}: let
  isDerivation = value: builtins.isAttrs value && (value.type or null) == "derivation";
  flatten = value:
    if builtins.isList value
    then builtins.concatMap flatten value
    else if value == null
    then []
    else [value];
  listFields = [
    "nativeBuildInputs"
    "buildInputs"
    "nativeCheckInputs"
    "propagatedNativeBuildInputs"
    "propagatedBuildInputs"
    "depsBuildBuild"
    "depsBuildHost"
    "depsBuildTarget"
    "depsHostHost"
    "depsHostTarget"
    "depsTargetTarget"
  ];
  sourceFields = ["src" "dummySrc" "cargoVendorDir" "cargoLock"];
  actualField = producer: field: let
    attrs = producer.drvAttrs;
    values = [(attrs.${field} or null) (producer.${field} or null)];
    materialized = value:
      if value == null
      then []
      else if isDerivation value || builtins.isPath value || builtins.isString value
      then [value]
      else if field == "cargoLock" && builtins.isAttrs value
      then [] # A parsed/contents lock record is data, not a seed output.
      else throw "recipe-seeds: unsupported actual ${field} input shape";
  in
    builtins.concatMap materialized values;
  materializerInputs = producer: builtins.concatMap (actualField producer) sourceFields;
  declaredInputs = producer: let
    attrs = producer.drvAttrs;
  in
    builtins.concatMap (field: flatten (attrs.${field} or null)) listFields
    ++ materializerInputs producer
    ++ actualField producer "stdenv";
  # Walk only source/vendor/lock materializers. Read their direct declared tools
  # and sources, without following compiler/native bootstrap derivation graphs.
  # Compiled project producers are still excluded at every step.
  sourceMaterializers = queue: visited:
    if queue == []
    then []
    else let
      producer = builtins.head queue;
      rest = builtins.tail queue;
      key = builtins.unsafeDiscardStringContext producer.drvPath;
    in
      if builtins.elem key visited || !allowed producer
      then sourceMaterializers rest visited
      else
        [producer]
        ++ sourceMaterializers (rest ++ builtins.filter isDerivation (materializerInputs producer)) (visited ++ [key]);
  sourceProducers = sourceMaterializers (builtins.filter isDerivation (builtins.concatMap materializerInputs producers)) [];
  candidates =
    builtins.concatMap declaredInputs (producers ++ sourceProducers)
    ++ extraInputs;
  rootString = value: let
    path = toString value;
    prefix = "${builtins.storeDir}/";
    relative = builtins.substring (builtins.stringLength prefix) (builtins.stringLength path) path;
    rootName = builtins.head (builtins.filter builtins.isString (builtins.split "/" relative));
  in
    if builtins.substring 0 (builtins.stringLength prefix) path != prefix
    then throw "recipe-seeds: actual declared input is not a public store root"
    else "${prefix}${rootName}";
  allowed = value:
    if !(isDerivation value || builtins.isPath value || builtins.isString value)
    then throw "recipe-seeds: unsupported actual declared input shape"
    else !(builtins.elem (builtins.unsafeDiscardStringContext (rootString value)) excludedOutputs);
  # Keep derivation output dependencies for not-yet-realized allowed inputs.
  # Preserve exact registered root context for already materialized source paths.
  root = value:
    if isDerivation value
    then value
    else builtins.storePath (rootString value);
  selected = map root (builtins.filter allowed candidates);
  unique = builtins.foldl' (acc: value:
    if builtins.any (item: toString item == toString value) acc
    then acc
    else acc ++ [value]) []
  selected;
in
  unique
