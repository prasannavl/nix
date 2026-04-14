let
  pkg = import ./pkg-helper.nix;
  serviceModuleFactory = import ./service-module.nix;
in rec {
  inherit pkg;
  srv = serviceModuleFactory.mkServiceLib {
    defaultClientSecretsBasePath = ../../data/secrets/services;
    defaultClientIdentitySuffix = "p7log.com";
    defaultClientSecretOwner = "pvl";
    defaultClientSecretGroup = "pvl";
    defaultServiceIdentitySuffix = "srv.z.p7log.com";
    defaultServiceSecretOwner = "root";
    defaultServiceSecretGroup = "root";
    defaultPostgresUrl = "postgresql://postgres@127.0.0.1:5432/pvl?sslmode=verify-full";
    defaultPostgresCaCertPath = "/run/agenix/pvl-ca-cert";
    defaultNatsUrl = "tls://127.0.0.1:4222";
    defaultNatsCaCertPath = "/run/agenix/pvl-ca-cert";
  };
}
