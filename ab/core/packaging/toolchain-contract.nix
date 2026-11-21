let
  isDerivation = value:
    builtins.isAttrs value && (value.type or null) == "derivation";

  attrOrNull = attrs: name: let
    value =
      if builtins.hasAttr name attrs
      then builtins.tryEval (builtins.getAttr name attrs)
      else {success = false;};
  in
    if value.success
    then value.value
    else null;

  optionalString = fail: name: value:
    if value == null || (builtins.isString value && value != "")
    then value
    else fail "`${name}` must be a non-empty string";

  result = {
    language,
    default,
    pkg,
    provider,
    fail,
    tools ? {},
    build ? {},
  }:
    if !isDerivation pkg
    then fail "provider `${provider}` did not return a package"
    else {
      inherit pkg tools build provider;
      id = "${language}:${pkg}";
      custom = toString pkg != toString default;
    };

  parse = {
    language,
    contract,
    defaultProvider,
    allowedFields,
    requiredFields ? {},
  }: let
    fail = message: throw "${language}-toolchain: ${message}";
    spec =
      if contract == null
      then {}
      else if builtins.isAttrs contract && !isDerivation contract
      then contract
      else fail "expected null or a toolchain contract";
    rawProvider = spec.provider or defaultProvider;
    provider =
      if builtins.isString rawProvider && rawProvider != ""
      then rawProvider
      else fail "`provider` must be a non-empty string";
    fields =
      if builtins.hasAttr provider allowedFields
      then allowedFields.${provider}
      else fail "unknown provider `${provider}`";
    unknown = builtins.removeAttrs spec fields;
    missing =
      builtins.filter
      (name: !(builtins.hasAttr name spec))
      (requiredFields.${provider} or []);
  in
    if unknown != {}
    then fail "unsupported fields for `${provider}`: ${builtins.concatStringsSep ", " (builtins.attrNames unknown)}"
    else if missing != []
    then fail "provider `${provider}` requires: ${builtins.concatStringsSep ", " missing}"
    else {
      inherit provider spec fail;
    };
in {
  inherit attrOrNull isDerivation optionalString parse result;
}
