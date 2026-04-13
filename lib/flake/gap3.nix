let
  pkg = import ./pkg-helper.nix;
  serviceModuleFactory = import ./service-module.nix;
in rec {
  inherit pkg;
  srv = serviceModuleFactory.mkServiceLib {
    defaultClientSecretsBasePath = ../../data/secrets/nats/clients;
    defaultClientIdentitySuffix = "gap3.ai";
    defaultClientSecretOwner = "gap3";
    defaultClientSecretGroup = "gap3";
    defaultServiceIdentitySuffix = "srv.gap3.ai";
    defaultServiceSecretOwner = "root";
    defaultServiceSecretGroup = "root";
    defaultPostgresUrl = "postgresql://postgres@127.0.0.1:5432/gap3?sslmode=verify-full";
    defaultPostgresCaCertPath = "/run/agenix/gap3-ca-cert";
    defaultNatsUrl = "tls://127.0.0.1:4222";
    defaultNatsCaCertPath = "/run/agenix/gap3-ca-cert";
  };
}
