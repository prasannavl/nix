# Bounded caller compilation context. This is not an artifact certificate:
# admission still reconstructs actual producers with the projected attributes.
let
  fail = message: throw "pkg-helper.rustCompileContext: ${message}";
  isDerivation = value: builtins.isAttrs value && (value.type or null) == "derivation";
  compileFields = ["nativeBuildInputs" "buildInputs" "nativeCheckInputs" "lintNativeBuildInputs" "env"];
  packagingFields = ["doCheck" "postInstall" "meta"];
  allowedFields = compileFields ++ packagingFields;
  # A positive boundary, not a parser for Rust/Cargo/native compiler flags.
  envNames = [
    "PKG_CONFIG_PATH"
    "PKG_CONFIG_LIBDIR"
    "OPENSSL_DIR"
    "OPENSSL_INCLUDE_DIR"
    "OPENSSL_LIB_DIR"
    "OPENSSL_STATIC"
    "PROTOC"
    "PROTOC_INCLUDE"
    "LIBCLANG_PATH"
  ];
  envValue = value:
    if builtins.isPath value
    then "${value}"
    else if builtins.isString value || isDerivation value
    then builtins.toString value
    else fail "environment values must be strings, paths or derivations";
  normalizeEnv = env:
    if !builtins.isAttrs env || !builtins.all (name: builtins.elem name envNames) (builtins.attrNames env)
    then fail "unsupported compilation environment name or shape"
    else builtins.mapAttrs (_name: value: envValue value) env;
  recordGuard = record:
    if !builtins.isAttrs record
    then fail "buildAttrs must be an attribute set"
    else if !builtins.all (name: builtins.elem name allowedFields) (builtins.attrNames record)
    then fail "unsupported build attribute; hooks, stdenv, flags and artifact controls are not projected"
    else if
      !builtins.all (name: let inputs = record.${name} or []; in builtins.isList inputs && builtins.all isDerivation inputs)
      ["nativeBuildInputs" "buildInputs" "nativeCheckInputs" "lintNativeBuildInputs"]
    then fail "declared compilation inputs must be ordered lists of derivations"
    else if record ? doCheck && !builtins.isBool record.doCheck
    then fail "doCheck must be boolean"
    else if record ? postInstall && !builtins.isString record.postInstall
    then fail "postInstall must be a string"
    else if record ? meta && !builtins.isAttrs record.meta
    then fail "meta must be an attribute set"
    else true;
  projectRecord = {
    selectedToolchain,
    record,
  }: let
    nativeInputs = (record.nativeBuildInputs or []) ++ (record.nativeCheckInputs or []) ++ (record.lintNativeBuildInputs or []);
    inputs = record.buildInputs or [];
    env = normalizeEnv (record.env or {});
  in
    builtins.seq (
      if builtins.isAttrs record
      then true
      else fail "buildAttrs must be an attribute set"
    )
    (builtins.seq (selectedToolchain.validateBuildAttrs record)
      (builtins.seq (recordGuard record) (builtins.deepSeq env (
        (
          if nativeInputs == []
          then {}
          else {nativeBuildInputs = nativeInputs;}
        )
        // (
          if inputs == []
          then {}
          else {buildInputs = inputs;}
        )
        // (
          if env == {}
          then {}
          else {env = env;}
        )
      ))));
  projectConsumer = {
    selectedToolchain,
    buildArgs,
    args,
  }: let
    attrs = args.buildAttrs or {};
    inputGuard =
      if !builtins.isAttrs args || !builtins.isAttrs buildArgs || !builtins.isAttrs attrs
      then fail "consumer arguments and build attributes must be attribute sets"
      else if !builtins.all (name: let inputs = args.${name} or []; in builtins.isList inputs && builtins.all isDerivation inputs) ["nativeCheckInputs" "lintNativeBuildInputs"]
      then fail "named compilation inputs must be ordered lists of derivations"
      else true;
    effective = buildArgs // attrs;
    selected = builtins.intersectAttrs (builtins.listToAttrs (map (name: {
        inherit name;
        value = true;
      })
      compileFields))
    effective;
    record =
      selected
      // {
        nativeCheckInputs = (args.nativeCheckInputs or []) ++ (effective.nativeCheckInputs or []);
        lintNativeBuildInputs = (args.lintNativeBuildInputs or []) ++ (effective.lintNativeBuildInputs or []);
      };
    compileAttrs = projectRecord {inherit selectedToolchain record;};
    checkEnv = normalizeEnv (args.checkEnv or {});
    checkGuard = builtins.all (name: (compileAttrs.env or {}) ? ${name} && checkEnv.${name} == compileAttrs.env.${name}) (builtins.attrNames checkEnv);
    packagingAttrs =
      builtins.intersectAttrs (builtins.listToAttrs (map (name: {
          inherit name;
          value = true;
        })
        packagingFields))
      effective
      // {meta = effective.meta or (args.meta or {});};
  in
    builtins.seq inputGuard (builtins.seq (selectedToolchain.validateBuildAttrs effective)
      (builtins.seq (selectedToolchain.validateBuildAttrs {env = args.checkEnv or {};})
        (builtins.seq (recordGuard effective) (builtins.seq (recordGuard packagingAttrs) (builtins.deepSeq checkEnv (
          if !checkGuard
          then fail "checkEnv must be empty or redundant with the shared compilation environment"
          else builtins.seq compileAttrs {inherit compileAttrs packagingAttrs;}
        ))))));
in {inherit projectRecord projectConsumer;}
