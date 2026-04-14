let
  pkg = import ./pkg-helper.nix;
  serviceModuleFactory = import ./service-module.nix;
in rec {
  inherit pkg;
  srv = serviceModuleFactory.mkServiceLib {
    defaultUser = "pvl";
    defaultClientSecretsBasePath = ../../data/secrets/services;
    defaultClientIdentitySuffix = "p7log.com";
    defaultClientSecretOwner = "pvl";
    defaultClientSecretGroup = "pvl";
    defaultServiceIdentitySuffix = "srv.z.p7log.com";
    defaultServiceSecretOwner = "pvl";
    defaultServiceSecretGroup = "pvl";
    defaultPostgresUrl = "postgresql://postgres@127.0.0.1:5432/pvl?sslmode=verify-ca";
    defaultPostgresCaCertPath = "/run/agenix/pvl-ca-cert";
    defaultPostgresAfter = ["pvl-postgres.service"];
    defaultNatsUrl = "tls://127.0.0.1:4222";
    defaultNatsCaCertPath = "/run/agenix/pvl-ca-cert";
    defaultNatsAfter = ["pvl-nats.service"];
  };
}
