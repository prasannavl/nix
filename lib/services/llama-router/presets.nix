let
  concat = builtins.concatStringsSep;
  validOptionName = name:
    builtins.isString name
    && builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null;
  validOptionValue = value:
    builtins.isString value
    && builtins.match "[^\r\n]+" value != null;
  validSectionName = name:
    builtins.isString name
    && builtins.match "[^][\r\n]+" name != null;
  validOptions = options:
    builtins.isAttrs options
    && builtins.all
    (name: validOptionName name && validOptionValue options.${name})
    (builtins.attrNames options);
  validModelRef = ref:
    builtins.isString ref
    && builtins.match "[^/ \t\r\n]+/[^/ \t\r\n]+(:[^/ \t\r\n]+)?" ref != null;
  renderSection = name: options:
    "[${name}]\n"
    + concat "" (builtins.map (key: "${key} = ${options.${key}}\n") (builtins.attrNames options));
in {
  inherit validModelRef validOptionName validOptionValue validOptions validSectionName;

  renderModelsPresetIni = {
    globalPreset ? {},
    modelPresets ? {},
    requiredModels,
  }: let
    presetModels = builtins.filter (model: modelPresets ? ${model}) requiredModels;
    presetName = model: (modelPresets.${model}.alias or model);
    globalSection =
      if globalPreset == {}
      then ""
      else (renderSection "*" globalPreset) + "\n";
  in
    globalSection
    + concat "" (builtins.map
      (model:
        renderSection
        (presetName model)
        ({hf = model;} // (modelPresets.${model} or {})))
      presetModels);
}
