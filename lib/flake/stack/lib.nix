{
  stackName,
  org,
  env,
  defaultMailDomain,
  publicDomain ? defaultMailDomain,
  internalDomain ? "${org}.internal",
  defaultUser,
  defaultClientSecretsBasePath,
  defaultNatsSecretsBasePath ? null,
  defaultPostgresSecretsBasePath ? null,
  defaultVmstackSecretsBasePath ? null,
  defaultNginxSecretsBasePath ? null,
  defaultCaCertAgeFile ? defaultClientSecretsBasePath + "/ca.crt.age",
  defaultCaCertHostPath ? "/etc/ssl/certs/${stackName}-ca.crt",
  defaultCaCertContainerPath ? "/run/secrets/${stackName}-ca.crt",
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
  serviceRegistry ? {},
}: let
  pkg = import ../pkg-helper.nix;
  serviceModuleFactory = import ../service-module.nix;
  userData = import ./users.nix {
    inherit defaultMailDomain stackName;
  };
in {
  pkg = pkg;
  stackName = stackName;
  org = org;
  env = env;
  defaultMailDomain = defaultMailDomain;
  publicDomain = publicDomain;
  internalDomain = internalDomain;
  users = userData.userData;
  userLib = userData.lib;
  userSets = userData.userSets;
  groupSets = userData.groupSets;
  groupData = userData.groupData;
  nixosConfig = userData.nixosConfig;
  registry = serviceRegistry;
  serviceRegistry = serviceRegistry;
  secrets = {
    services = defaultClientSecretsBasePath;
    nats = defaultNatsSecretsBasePath;
    postgres = defaultPostgresSecretsBasePath;
    vmstack = defaultVmstackSecretsBasePath;
    nginx = defaultNginxSecretsBasePath;
  };
  defaultNginxSecretsBasePath = defaultNginxSecretsBasePath;
  defaultNginxSecretsBase = defaultNginxSecretsBasePath;
  defaultCaCertAgeFile = defaultCaCertAgeFile;
  defaultCaCertHostPath = defaultCaCertHostPath;
  defaultCaCertContainerPath = defaultCaCertContainerPath;
  defaultCaCertificate = {
    file = defaultCaCertHostPath;
    sourceHashFile =
      if builtins.pathExists defaultCaCertAgeFile
      then defaultCaCertAgeFile
      else null;
    mountPath = defaultCaCertContainerPath;
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
