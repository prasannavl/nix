{
  stackName,
  org,
  env,
  defaultMailDomain,
  publicDomain ? defaultMailDomain,
  internalDomain ? "${org}.internal",
  defaultUser,
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
  secretsLib = import ../secrets.nix;
  pkg = import ../pkg-helper.nix;
  serviceModuleFactory = import ../service-module.nix;
  unitsLib = import ../units.nix;
  nginxIngressComposerLib = import ../../services/nginx/ingress-composer.nix;
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
  userData = import ./users.nix {
    inherit defaultMailDomain stackName;
  };
in {
  pkg = pkg;
  stackName = stackName;
  org = org;
  env = env;
  secretScope = secretScope;
  defaultMailDomain = defaultMailDomain;
  noReplyEmailFor = appName: "no-reply+${appName}@${defaultMailDomain}";
  publicDomain = publicDomain;
  internalDomain = internalDomain;
  users = userData.userData;
  userLib = userData.lib;
  userSets = userData.userSets;
  groupSets = userData.groupSets;
  groupData = userData.groupData;
  nixosConfig = userData.nixosConfig;
  lib = {
    units = unitsLib;
    mkNginxLib = {
      lib,
      registry,
    }: let
      nginxService = import ../../services/nginx {inherit lib;};
      ingressComposer = nginxIngressComposerLib.mkIngressComposer {
        inherit lib;
        serviceRegistry = registry;
        rateLimitProfiles = nginxService.rateLimitProfiles;
      };
      rawLimits = registry.limits or {};
      rawTimeouts = rawLimits.timeouts or {};
      resolvedLimits =
        rawLimits
        // (
          if builtins.attrNames rawTimeouts != []
          then {timeouts = nginxService.mkTimeouts rawTimeouts;}
          else {}
        );
    in
      nginxService
      // ingressComposer
      // {
        rawLimits = rawLimits;
        limits = resolvedLimits;
        ingressComposer = ingressComposer;
        service = nginxService;
        inherit (unitsLib) sizeToBytes sizesToBytes;
      };
  };
  secrets = rec {
    base = stackSecretsBasePath;
    labelBase = stackSecretsLabel;
    scope = secretScope;
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
  defaultNginxSecretsBasePath = defaultNginxSecretsBasePath;
  defaultNginxSecretsBase = defaultNginxSecretsBasePath;
  defaultCaCertBasePath = defaultCaCertBasePath;
  defaultCaCertFile = resolvedDefaultCaCertFile;
  defaultCaCertAgeFile = resolvedDefaultCaCertAgeFile;
  defaultCaCertHostPath = defaultCaCertHostPath;
  defaultCaCertContainerPath = defaultCaCertContainerPath;
  defaultCaBundleHostPath = defaultCaBundleHostPath;
  defaultCaBundleContainerPath = defaultCaBundleContainerPath;
  defaultCaCertificate = {
    file = defaultCaCertHostPath;
    sourceHashFile = resolvedDefaultCaCertFile;
    mountPath = defaultCaCertContainerPath;
  };
  defaultCaBundleCertificate = {
    file = defaultCaBundleHostPath;
    sourceHashFile = resolvedDefaultCaCertFile;
    mountPath = defaultCaBundleContainerPath;
  };
  srv = serviceModuleFactory.mkServiceLib {
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
}
