{
  stackName,
  org,
  env,
  defaultMailDomain,
  publicDomain ? defaultMailDomain,
  internalDomain ? "${org}.internal",
  defaultUser,
  stackSecretsBasePath ? defaultClientSecretsBasePath,
  defaultClientSecretsBasePath,
  defaultNatsSecretsBasePath ? null,
  defaultPostgresSecretsBasePath ? null,
  defaultVmstackSecretsBasePath ? null,
  defaultNginxSecretsBasePath ? null,
  defaultCaCertFile ? null,
  defaultCaCertAgeFile ? stackSecretsBasePath + "/ca/ca.crt.age",
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
  defaultPostgresCaCertPath,
  defaultPostgresAfter ? [],
  defaultNatsUrl,
  defaultNatsCaCertPath,
  defaultNatsAfter ? [],
}: let
  pkg = import ../pkg-helper.nix;
  serviceModuleFactory = import ../service-module.nix;
  unitsLib = import ../units.nix;
  nginxIngressComposerLib = import ../../services/nginx/ingress-composer.nix;
  userData = import ./users.nix {
    inherit defaultMailDomain stackName;
  };
in {
  pkg = pkg;
  stackName = stackName;
  org = org;
  env = env;
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
        serviceRegistry = registry;
        rateLimitProfiles = nginxService.rateLimitProfiles;
      };
      rawLimits = registry.limits or {};
      resolvedLimits =
        rawLimits
        // (
          if rawLimits ? proxyTimeouts
          then {proxyTimeouts = nginxService.mkProxyTimeouts rawLimits.proxyTimeouts;}
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
  defaultCaCertFile = defaultCaCertFile;
  defaultCaCertAgeFile = defaultCaCertAgeFile;
  defaultCaCertHostPath = defaultCaCertHostPath;
  defaultCaCertContainerPath = defaultCaCertContainerPath;
  defaultCaBundleHostPath = defaultCaBundleHostPath;
  defaultCaBundleContainerPath = defaultCaBundleContainerPath;
  defaultCaCertificate = {
    file = defaultCaCertHostPath;
    sourceHashFile = defaultCaCertFile;
    mountPath = defaultCaCertContainerPath;
  };
  defaultCaBundleCertificate = {
    file = defaultCaBundleHostPath;
    sourceHashFile = defaultCaCertFile;
    mountPath = defaultCaBundleContainerPath;
  };
  srv = serviceModuleFactory.mkServiceLib {
    defaultUser = defaultUser;
    defaultClientSecretsBasePath = defaultClientSecretsBasePath;
    defaultNatsSecretsBasePath = defaultNatsSecretsBasePath;
    defaultPostgresSecretsBasePath = defaultPostgresSecretsBasePath;
    defaultVmstackSecretsBasePath = defaultVmstackSecretsBasePath;
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
