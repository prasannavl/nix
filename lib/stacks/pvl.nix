let
  base = import ../flake/stack/lib.nix {
    stackName = "pvl";
    org = "pvl";
    env = "prod";
    defaultMailDomain = "p7log.com";
    publicDomain = "p7log.com";
    internalDomain = "pvl.internal";
    defaultUser = "pvl";
    stackSecretsBasePath = ../../data/secrets/pvl;
    defaultClientSecretsBasePath = ../../data/secrets/pvl/services;
    defaultCaCertAgeFile = ../../data/secrets/pvl/ca/ca.crt.age;
    defaultNatsSecretsBasePath = ../../data/secrets/pvl/nats;
    defaultPostgresSecretsBasePath = ../../data/secrets/pvl/postgres;
    defaultVmstackSecretsBasePath = ../../data/secrets/pvl/vmstack;
    defaultClientIdentitySuffix = "p7log.com";
    defaultExtServiceIdentitySuffix = "p7log.com";
    defaultSecretOwner = "pvl";
    defaultSecretGroup = "pvl";
    defaultServiceIdentitySuffix = "srv.z.p7log.com";
    defaultPostgresUrl = "postgresql://postgres@127.0.0.1:5432/pvl?sslmode=verify-ca";
    defaultPostgresCaCertPath = "/run/agenix/pvl-ca-cert";
    defaultPostgresAfter = ["pvl-postgres.service"];
    defaultNatsUrl = "tls://127.0.0.1:4222";
    defaultNatsCaCertPath = "/run/agenix/pvl-ca-cert";
    defaultNatsAfter = ["pvl-nats.service"];
  };
in
  base
  // {
    serviceRegistry = {
      limits = {};
    };
  }
