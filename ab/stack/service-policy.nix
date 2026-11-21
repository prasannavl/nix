{
  defaultUser ? "root",
  stackName ? defaultUser,
  defaultClientRuntimeBasePath ? "/run/agenix",
  defaultClientSecretsBasePath,
  defaultNatsSecretsBasePath ? null,
  defaultPostgresSecretsBasePath ? null,
  defaultVmstackSecretsBasePath ? null,
  secretScope ? null,
  defaultClientIdentitySuffix ? null,
  defaultExtServiceRuntimeBasePath ? "/run/agenix",
  defaultExtServiceIdentitySuffix ? null,
  defaultServiceIdentitySuffix,
  defaultSecretOwner ? "root",
  defaultSecretGroup ? "root",
  defaultSecretMode ? "0400",
  defaultPostgresUrl,
  defaultPostgresCaCertPath,
  defaultPostgresAfter ? [],
  defaultNatsUrl,
  defaultNatsCaCertPath,
  defaultNatsAfter ? [],
}: let
  hasSecretScope = secretScope != null && secretScope != "";
  scopedFileName = name:
    if !hasSecretScope
    then name
    else "${secretScope}-${name}";

  trackedPath = path: name:
    if builtins.pathExists path
    then builtins.path {inherit path name;}
    else null;

  mkIdentityHost = name: suffix: "${name}.${suffix}";
  mkIdentityUser = name: suffix: "${name}@${suffix}";
  mkIdentityCertFileName = name: suffix: "${mkIdentityHost name suffix}.crt";
  mkIdentityKeyFileName = name: suffix: "${mkIdentityHost name suffix}.key";
  mkHostSuffixName = label: name: "${name}-${label}";

  mkIdentityCore = args @ {
    name ? null,
    pname ? null,
    sourcePath ? null,
    family ? null,
    label ? null,
    suffix ? null,
    secretsBasePath ? null,
    certSecretFileName ? null,
    keySecretFileName ? null,
    runtimeBasePath ? null,
    secretOwner ? null,
    secretGroup ? null,
    secretMode ? null,
  }: let
    resolvedName =
      if name != null
      then name
      else if pname != null
      then pname
      else if sourcePath != null
      then builtins.baseNameOf sourcePath
      else throw "service-policy.mkIdentity: name, pname, or sourcePath is required";
    resolvedFamily = family;
    resolvedLabel = label;
    isExtService = resolvedFamily != null;
    resolvedSuffix =
      if suffix != null
      then suffix
      else if isExtService
      then
        if defaultExtServiceIdentitySuffix != null
        then defaultExtServiceIdentitySuffix
        else throw "service-policy.mkIdentity: suffix is required when no defaultExtServiceIdentitySuffix is configured"
      else if defaultClientIdentitySuffix != null
      then defaultClientIdentitySuffix
      else throw "service-policy.mkIdentity: suffix is required when no defaultClientIdentitySuffix is configured";
    resolvedFullName =
      if resolvedLabel != null
      then mkHostSuffixName resolvedLabel resolvedName
      else resolvedName;
    resolvedSecretsBasePath =
      if secretsBasePath != null
      then secretsBasePath
      else if isExtService
      then throw "service-policy.mkIdentity: secretsBasePath is required when family is set"
      else defaultClientSecretsBasePath + "/${resolvedFullName}";
    rawCertSecretFileName =
      if certSecretFileName != null
      then certSecretFileName
      else if isExtService
      then
        if resolvedLabel != null
        then "${resolvedLabel}.crt.age"
        else "${resolvedName}.crt.age"
      else "crt.age";
    rawKeySecretFileName =
      if keySecretFileName != null
      then keySecretFileName
      else if isExtService
      then
        if resolvedLabel != null
        then "${resolvedLabel}.key.age"
        else "${resolvedName}.key.age"
      else "key.age";
    resolvedCertSecretFileName = scopedFileName rawCertSecretFileName;
    resolvedKeySecretFileName = scopedFileName rawKeySecretFileName;
    resolvedRuntimeBasePath =
      if runtimeBasePath != null
      then runtimeBasePath
      else if isExtService
      then defaultExtServiceRuntimeBasePath
      else defaultClientRuntimeBasePath;
    resolvedSecretOwner =
      if secretOwner != null
      then secretOwner
      else defaultSecretOwner;
    resolvedSecretGroup =
      if secretGroup != null
      then secretGroup
      else defaultSecretGroup;
    resolvedSecretMode =
      if secretMode != null
      then secretMode
      else defaultSecretMode;
    resolvedRuntimeName =
      if isExtService
      then resolvedFullName
      else mkIdentityHost resolvedFullName resolvedSuffix;
    certFileName =
      if isExtService
      then "${resolvedRuntimeName}.crt"
      else mkIdentityCertFileName resolvedFullName resolvedSuffix;
    keyFileName =
      if isExtService
      then "${resolvedRuntimeName}.key"
      else mkIdentityKeyFileName resolvedFullName resolvedSuffix;
    certFile =
      trackedPath
      (resolvedSecretsBasePath + "/${resolvedCertSecretFileName}")
      "${resolvedFullName}-${resolvedCertSecretFileName}";
    keyFile =
      trackedPath
      (resolvedSecretsBasePath + "/${resolvedKeySecretFileName}")
      "${resolvedFullName}-${resolvedKeySecretFileName}";
    secretDefaults = {
      owner = resolvedSecretOwner;
      group = resolvedSecretGroup;
      mode = resolvedSecretMode;
    };
  in rec {
    inherit
      resolvedName
      resolvedFamily
      resolvedLabel
      resolvedSuffix
      sourcePath
      resolvedRuntimeBasePath
      resolvedSecretOwner
      resolvedSecretGroup
      resolvedSecretMode
      certFileName
      keyFileName
      certFile
      keyFile
      secretDefaults
      ;
    secretsBasePath = resolvedSecretsBasePath;
    __functor = _: overrideArgs: mkIdentityCore (args // overrideArgs);
    name = resolvedName;
    pname = resolvedName;
    family = resolvedFamily;
    label = resolvedLabel;
    suffix = resolvedSuffix;
    fullName = resolvedFullName;
    certSecretFileName = resolvedCertSecretFileName;
    keySecretFileName = resolvedKeySecretFileName;
    runtimeBasePath = resolvedRuntimeBasePath;
    secretOwner = resolvedSecretOwner;
    secretGroup = resolvedSecretGroup;
    secretMode = resolvedSecretMode;
    host = mkIdentityHost resolvedFullName resolvedSuffix;
    user = mkIdentityUser resolvedFullName resolvedSuffix;
    certRuntimePath = "${resolvedRuntimeBasePath}/${certFileName}";
    keyRuntimePath = "${resolvedRuntimeBasePath}/${keyFileName}";
    ageSecrets =
      (
        if certFile != null
        then {"${certFileName}" = {file = certFile;} // secretDefaults;}
        else {}
      )
      // (
        if keyFile != null
        then {"${keyFileName}" = {file = keyFile;} // secretDefaults;}
        else {}
      );
    nixosModule.age.secrets = ageSecrets;
    flakeExtraNixosModules.clientIdentity = nixosModule;
  };
in rec {
  inherit
    stackName
    defaultUser
    defaultClientRuntimeBasePath
    defaultClientSecretsBasePath
    defaultNatsSecretsBasePath
    defaultPostgresSecretsBasePath
    defaultVmstackSecretsBasePath
    secretScope
    defaultClientIdentitySuffix
    defaultExtServiceRuntimeBasePath
    defaultExtServiceIdentitySuffix
    defaultServiceIdentitySuffix
    defaultSecretOwner
    defaultSecretGroup
    defaultSecretMode
    defaultPostgresUrl
    defaultPostgresCaCertPath
    defaultPostgresAfter
    defaultNatsUrl
    defaultNatsCaCertPath
    defaultNatsAfter
    trackedPath
    ;

  mkSecret = file: overrides:
    {
      inherit file;
      owner = defaultSecretOwner;
      group = defaultSecretGroup;
      mode = defaultSecretMode;
    }
    // overrides;

  mkServiceSecretPath = serviceName: fileName:
    defaultClientSecretsBasePath + "/${serviceName}/${scopedFileName fileName}";

  mkServiceKeySecretPath = serviceName: secretName:
    mkServiceSecretPath serviceName "${secretName}.key.age";

  sanitizeStoreName = name:
    builtins.replaceStrings ["." "/"] ["-" "-"] name;

  mkTrackedServiceSecretStoreName = serviceName: fileName: "${stackName}-${serviceName}-${sanitizeStoreName fileName}";

  mkTrackedServiceSecretPath = serviceName: fileName:
    trackedPath
    (mkServiceSecretPath serviceName fileName)
    (mkTrackedServiceSecretStoreName serviceName fileName);

  mkTrackedServiceKeySecretPath = serviceName: secretName:
    trackedPath
    (mkServiceKeySecretPath serviceName secretName)
    "${stackName}-${serviceName}-${secretName}-age";

  mkServiceSecret = serviceName: secretName: overrides:
    mkSecret (mkServiceKeySecretPath serviceName secretName) overrides;

  mkServiceSecrets = serviceName:
    builtins.mapAttrs (secretName: spec: let
      sourceName = spec.sourceName or secretName;
      file = spec.file or (mkServiceKeySecretPath serviceName sourceName);
    in
      mkSecret file (builtins.removeAttrs spec ["file" "sourceName"]));

  inherit
    mkIdentityHost
    mkIdentityUser
    mkIdentityCertFileName
    mkIdentityKeyFileName
    ;

  mkIdentity = args:
    if !builtins.isAttrs args || (args.type or null) == "derivation"
    then throw "service-policy.mkIdentity: pass explicit identity attributes, not a derivation"
    else mkIdentityCore args;

  bindIdentity = intent:
    if !builtins.isAttrs intent || (intent.type or null) == "derivation"
    then throw "service-policy.bindIdentity: pass a neutral identity intent, not a derivation"
    else if builtins.attrNames intent != ["name"]
    then throw "service-policy.bindIdentity: identity intent must contain only name"
    else if !builtins.isString intent.name || intent.name == ""
    then throw "service-policy.bindIdentity: identity intent name must be a non-empty string"
    else mkIdentity intent;

  mkIdentityForVectorHub = args @ {secretsBasePath ? null, ...}: let
    vectorSecretsBasePath =
      if secretsBasePath != null
      then secretsBasePath
      else defaultClientSecretsBasePath + "/vector";
  in
    mkIdentity (
      (builtins.removeAttrs args ["secretsBasePath"])
      // {
        name = "vector-hub";
        certSecretFileName = "hub.crt.age";
        keySecretFileName = "hub.key.age";
        secretsBasePath = vectorSecretsBasePath;
      }
    );

  mkIdentityForVectorAgent = args @ {
    hostLabel ? null,
    secretsBasePath ? null,
    ...
  }: let
    resolvedHostLabel =
      if hostLabel != null
      then hostLabel
      else throw "service-policy.mkIdentityForVectorAgent: hostLabel is required";
    vectorSecretsBasePath =
      if secretsBasePath != null
      then secretsBasePath
      else defaultClientSecretsBasePath + "/vector";
  in
    mkIdentity (
      (builtins.removeAttrs args ["hostLabel" "secretsBasePath"])
      // {
        name = "vector-agent-${resolvedHostLabel}";
        certSecretFileName = "agent-${resolvedHostLabel}.crt.age";
        keySecretFileName = "agent-${resolvedHostLabel}.key.age";
        secretsBasePath = vectorSecretsBasePath;
      }
    );

  mkIdentityForNats = args:
    mkIdentity (
      (builtins.removeAttrs args ["secretsBasePath"])
      // {
        family = "nats";
        name = "nats";
        secretsBasePath =
          if args ? secretsBasePath && args.secretsBasePath != null
          then args.secretsBasePath
          else if defaultNatsSecretsBasePath != null
          then defaultNatsSecretsBasePath
          else throw "service-policy.mkIdentityForNats: secretsBasePath is required";
      }
    );

  mkIdentityForPostgres = args:
    mkIdentity (
      (builtins.removeAttrs args ["secretsBasePath"])
      // {
        family = "postgres";
        name = "postgres";
        secretsBasePath =
          if args ? secretsBasePath && args.secretsBasePath != null
          then args.secretsBasePath
          else if defaultPostgresSecretsBasePath != null
          then defaultPostgresSecretsBasePath
          else throw "service-policy.mkIdentityForPostgres: secretsBasePath is required";
      }
    );

  mkIdentityForVmstack = args:
    mkIdentity (
      (builtins.removeAttrs args ["secretsBasePath"])
      // {
        family = "vmstack";
        name = "vmstack";
        secretsBasePath =
          if args ? secretsBasePath && args.secretsBasePath != null
          then args.secretsBasePath
          else if defaultVmstackSecretsBasePath != null
          then defaultVmstackSecretsBasePath
          else throw "service-policy.mkIdentityForVmstack: secretsBasePath is required";
      }
    );

  mkServiceIdentityHost = serviceName:
    mkIdentityHost serviceName defaultServiceIdentitySuffix;
  mkServiceIdentityUser = serviceName:
    mkIdentityUser serviceName defaultServiceIdentitySuffix;
  mkServiceIdentityCertFileName = serviceName:
    mkIdentityCertFileName serviceName defaultServiceIdentitySuffix;
  mkServiceIdentityKeyFileName = serviceName:
    mkIdentityKeyFileName serviceName defaultServiceIdentitySuffix;
}
