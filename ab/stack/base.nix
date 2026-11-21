{
  stackName,
  org,
  env,
  defaultMailDomain,
  rawUserdata,
  rawGroupData,
  publicDomain ? defaultMailDomain,
  internalDomain ? "${org}.internal",
  defaultUser,
  secretNamespace ? org,
  secretScope ? null,
  stackSecretsBasePath ? defaultClientSecretsBasePath,
  stackSecretsLabel ? toString stackSecretsBasePath,
  defaultClientSecretsBasePath,
  defaultNatsSecretsBasePath ? null,
  defaultPostgresSecretsBasePath ? null,
  defaultVmstackSecretsBasePath ? null,
  defaultNginxSecretsBasePath ? null,
  defaultCaCertBasePath ? null,
  defaultCaCertFile ? null,
  defaultCaCertAgeFile ? null,
  defaultCaCertHostPath ? "/etc/ssl/certs/${org}-ca.crt",
  defaultCaCertContainerPath ? "/run/secrets/${org}-ca.crt",
  defaultCaBundleHostPath ? "/etc/ssl/certs/${org}-ca-bundle.crt",
  defaultCaBundleContainerPath ? "/run/secrets/${org}-ca-bundle.crt",
  defaultClientIdentitySuffix,
  defaultExtServiceIdentitySuffix ? defaultClientIdentitySuffix,
  defaultServiceIdentitySuffix,
  defaultSecretOwner ? defaultUser,
  defaultSecretGroup ? defaultUser,
  defaultSecretMode ? "0400",
  defaultPostgresUrl,
  defaultPostgresCaCertPath ? defaultCaCertHostPath,
  defaultPostgresAfter ? [],
  defaultNatsUrl,
  defaultNatsCaCertPath ? defaultCaCertHostPath,
  defaultNatsAfter ? [],
}: let
  accountLib = import ./accounts;
  secretsLib = import ./secrets.nix;
  servicePolicy = import ./service-policy.nix;
  unitsLib = import ./units.nix;
  secretPaths = secretsLib.mkStack {
    base = stackSecretsBasePath;
    scope = secretScope;
  };
  secretLabels = secretsLib.mkStack {
    base = stackSecretsLabel;
    scope = secretScope;
  };
  caCertPaths = secretsLib.mkScope {
    base = defaultCaCertBasePath;
    scope = secretScope;
  };
  resolvedDefaultCaCertFile =
    if defaultCaCertFile != null
    then defaultCaCertFile
    else if defaultCaCertBasePath != null
    then caCertPaths.file "ca.crt"
    else null;
  resolvedDefaultCaCertAgeFile =
    if defaultCaCertAgeFile != null
    then defaultCaCertAgeFile
    else secretPaths.file "ca/ca.crt.age";
  accounts = accountLib.mk {
    inherit defaultMailDomain rawGroupData rawUserdata stackName;
  };
  policy = servicePolicy {
    stackName = stackName;
    defaultUser = defaultUser;
    defaultClientSecretsBasePath = defaultClientSecretsBasePath;
    defaultNatsSecretsBasePath = defaultNatsSecretsBasePath;
    defaultPostgresSecretsBasePath = defaultPostgresSecretsBasePath;
    defaultVmstackSecretsBasePath = defaultVmstackSecretsBasePath;
    secretScope = secretScope;
    defaultClientIdentitySuffix = defaultClientIdentitySuffix;
    defaultExtServiceIdentitySuffix = defaultExtServiceIdentitySuffix;
    defaultServiceIdentitySuffix = defaultServiceIdentitySuffix;
    defaultSecretOwner = defaultSecretOwner;
    defaultSecretGroup = defaultSecretGroup;
    defaultSecretMode = defaultSecretMode;
    defaultPostgresUrl = defaultPostgresUrl;
    defaultPostgresCaCertPath = defaultPostgresCaCertPath;
    defaultPostgresAfter = defaultPostgresAfter;
    defaultNatsUrl = defaultNatsUrl;
    defaultNatsCaCertPath = defaultNatsCaCertPath;
    defaultNatsAfter = defaultNatsAfter;
  };
in {
  accounts = accounts;
  name = stackName;
  environment = env;
  domains = {
    public = publicDomain;
    internal = internalDomain;
  };
  mail = {
    domain = defaultMailDomain;
    noReplyFor = appName: "no-reply+${appName}@${defaultMailDomain}";
  };
  lib.units = unitsLib;
  secrets = rec {
    namespace = secretNamespace;
    base = stackSecretsBasePath;
    labelBase = stackSecretsLabel;
    scope = secretScope;
    defaults = {
      owner = policy.defaultSecretOwner;
      group = policy.defaultSecretGroup;
      mode = policy.defaultSecretMode;
    };
    ageSecret = policy.mkSecret;
    tracked = policy.trackedPath;
    trackedServiceFile = policy.mkTrackedServiceSecretPath;
    trackedServiceKey = policy.mkTrackedServiceKeySecretPath;
    inherit
      (secretPaths)
      file
      key
      scopedFileName
      serviceFile
      serviceKey
      extFile
      extKey
      ;
    label = secretLabels.file;
    serviceLabel = secretLabels.serviceFile;
    extLabel = secretLabels.extFile;
    services = defaultClientSecretsBasePath;
    service = name: services + "/${name}";
    ext = provider: base + "/ext/${provider}";
    ca = base + "/ca";
    acme = base + "/acme";
    nats = defaultNatsSecretsBasePath;
    postgres = defaultPostgresSecretsBasePath;
    vmstack = defaultVmstackSecretsBasePath;
    nginx = defaultNginxSecretsBasePath;
  };
  certs = {
    ca = {
      basePath = defaultCaCertBasePath;
      sourceFile = resolvedDefaultCaCertFile;
      ageFile = resolvedDefaultCaCertAgeFile;
      hostPath = defaultCaCertHostPath;
      containerPath = defaultCaCertContainerPath;
      file = defaultCaCertHostPath;
      sourceHashFile = resolvedDefaultCaCertFile;
      mountPath = defaultCaCertContainerPath;
    };
    bundle = {
      hostPath = defaultCaBundleHostPath;
      containerPath = defaultCaBundleContainerPath;
      file = defaultCaBundleHostPath;
      sourceHashFile = resolvedDefaultCaCertFile;
      mountPath = defaultCaBundleContainerPath;
    };
  };
  postgres = {
    url = policy.defaultPostgresUrl;
    caCertPath = policy.defaultPostgresCaCertPath;
    after = policy.defaultPostgresAfter;
  };
  nats = {
    url = policy.defaultNatsUrl;
    caCertPath = policy.defaultNatsCaCertPath;
    after = policy.defaultNatsAfter;
  };
  service = {
    user = policy.defaultUser;
  };
  identity = {
    bind = policy.bindIdentity;
    mk = policy.mkIdentity;
    vectorHub = policy.mkIdentityForVectorHub;
    vectorAgent = policy.mkIdentityForVectorAgent;
    nats = policy.mkIdentityForNats;
    postgres = policy.mkIdentityForPostgres;
    vmstack = policy.mkIdentityForVmstack;
    serviceHost = policy.mkServiceIdentityHost;
    serviceUser = policy.mkServiceIdentityUser;
    serviceCertFileName = policy.mkServiceIdentityCertFileName;
    serviceKeyFileName = policy.mkServiceIdentityKeyFileName;
    clientSuffix = policy.defaultClientIdentitySuffix;
    externalServiceSuffix = policy.defaultExtServiceIdentitySuffix;
    serviceSuffix = policy.defaultServiceIdentitySuffix;
  };
}
