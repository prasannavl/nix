{lib}: {
  inputs,
  definitions,
  overlaysFor,
}: let
  mkInputSet = name: inputNames: let
    selected = builtins.mapAttrs (_: inputName: inputs.${inputName}) inputNames;
    inputSetInputs =
      inputs
      // lib.mapAttrs'
      (profileKey: inputName: lib.nameValuePair inputName selected.${profileKey})
      inputNames;
  in
    selected
    // {
      inherit name;
      inputs = inputSetInputs;
      overlays = overlaysFor inputSetInputs;
    };
in
  builtins.mapAttrs mkInputSet definitions
