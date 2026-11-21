{pkgs}: let
  services = (import ../default.nix {core = import ../../core;}).servicePolicy {
    defaultClientSecretsBasePath = ./.;
    defaultClientIdentitySuffix = "test";
    defaultServiceIdentitySuffix = "test";
    defaultPostgresUrl = "";
    defaultPostgresCaCertPath = "";
    defaultNatsUrl = "";
    defaultNatsCaCertPath = "";
  };
  identity = services.mkIdentity {
    name = "client";
    secretsBasePath = ./.;
    certSecretFileName = "service-client-identity.nix";
    keySecretFileName = "service-client-identity.nix";
  };
  boundIdentity = services.bindIdentity {name = "client";};
  derivationRejected = !(builtins.tryEval (services.mkIdentity pkgs.hello).host).success;
  boundDerivationRejected = !(builtins.tryEval (services.bindIdentity pkgs.hello).host).success;
  boundPolicyRejected =
    !(builtins.tryEval
      (services.bindIdentity {
        name = "client";
        suffix = "other";
      }).host).success;
in
  assert identity.host == "client.test";
  assert identity.user == "client@test";
  assert identity.certRuntimePath == "/run/agenix/client.test.crt";
  assert identity.keyRuntimePath == "/run/agenix/client.test.key";
  assert identity.certFile != null;
  assert identity.keyFile != null;
  assert builtins.attrNames identity.ageSecrets == ["client.test.crt" "client.test.key"];
  assert identity.nixosModule.age.secrets == identity.ageSecrets;
  assert boundIdentity.host == identity.host;
  assert boundIdentity.user == identity.user;
  assert derivationRejected;
  assert boundDerivationRejected;
  assert boundPolicyRejected;
    pkgs.runCommand "service-client-identity-test" {} ''touch "$out"''
