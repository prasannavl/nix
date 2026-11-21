{
  abCoreSource,
  abStackSource,
  nixpkgsPath,
  system,
}: let
  pkgs = import nixpkgsPath {inherit system;};
  core = import abCoreSource;
  ab = core.mk {inherit pkgs;};
  stackComponent = import abStackSource {inherit core;};
  accountData = {
    rawUserdata.alice = {
      uid = 1000;
      name = "Alice";
    };
    rawGroupData.users.users = ["alice"];
  };

  definition = {
    name = "external-stack";
    environment = "test";

    domains = {
      public = "example.test";
      internal = "example.internal";
    };

    topology.instances.api = {
      role = "app";
      host = "fixture-host";
    };

    network = {
      project = "external-stack";
      externalConnectors = false;
    };

    tunnels = {
      ingress = {};
      publications = {};
    };

    ingress = {
      http.proxies.api = {
        serverNames = ["api.example.test"];
        port = 18080;
        upstreams = ["127.0.0.1:18080"];
      };

      http.routes.health = {
        serverName = "api.example.test";
        path = "/health";
      };

      stream.proxies.smtp = {
        listenPort = 2525;
        upstream = "127.0.0.1:25";
      };
    };
  };

  stack = stackComponent.mk {
    inherit definition;
  };
  baseStack = stackComponent.mkBase ({
      stackName = "fixture-base";
      org = "fixture";
      env = "test";
      defaultMailDomain = "example.test";
      defaultUser = "fixture";
      defaultClientSecretsBasePath = "/secrets/fixture/services";
      defaultClientIdentitySuffix = "client.example.test";
      defaultServiceIdentitySuffix = "service.example.test";
      defaultPostgresUrl = "postgresql://postgres@db/fixture";
      defaultNatsUrl = "nats://nats";
    }
    // accountData);
in {
  inherit ab accountData baseStack core definition pkgs stack stackComponent;
}
