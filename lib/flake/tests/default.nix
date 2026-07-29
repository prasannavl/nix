{pkgs}: let
  system = pkgs.stdenv.hostPlatform.system;
  fakeFlakeUtils = {
    lib = {
      defaultSystems = [system];
      eachSystem = systems: f: let
        outputsBySystem = builtins.listToAttrs (
          map (name: {
            inherit name;
            value = f name;
          })
          systems
        );
        outputNames = pkgs.lib.unique (
          builtins.concatMap (name: builtins.attrNames outputsBySystem.${name}) systems
        );
      in
        builtins.listToAttrs (
          map (outputName: {
            name = outputName;
            value = builtins.listToAttrs (
              map (name: {
                inherit name;
                value = outputsBySystem.${name}.${outputName};
              })
              systems
            );
          })
          outputNames
        );
    };
  };
  flakeLib = import ../default.nix {
    inputs = {};
    nixpkgs = {lib = pkgs.lib;};
    flake-utils = fakeFlakeUtils;
    overlays = [];
    stackProfiles = {};
  };
  outputs = flakeLib.withPkgs pkgs;
  packageHelper = import ../pkg-helper.nix;
  nestedRustPackage = packageHelper.mkRustDerivation {
    pkgs = pkgs;
    build = pkgs.runCommand "nested-rust-package" {} ''
      touch "$out"
    '';
    src = ../../..;
    pname = "nested-rust-package";
    projectDir = "pkgs/examples/hello-rust/src";
    projectPath = "pkgs/examples/hello-rust";
  };
  nativeClientCaDefaultsStack = import ../stack/lib.nix {
    stackName = "test";
    org = "test";
    env = "test";
    defaultMailDomain = "example.test";
    defaultUser = "svc";
    defaultClientSecretsBasePath = "/secrets/client";
    defaultClientIdentitySuffix = "svc.example";
    defaultServiceIdentitySuffix = "svc.example";
    defaultPostgresUrl = "postgresql://postgres@db:5432/app?sslmode=verify-ca";
    defaultNatsUrl = "tls://nats:4222";
  };
  stackSetProfiles = let
    mkProfile = stackName: extra:
      {
        inherit stackName;
        env = "test";
        domain = "${stackName}.example.test";
        internalDomain = "${stackName}.internal";
        activeEndpointGroup = "live";
        endpointGroups.live = {
          project = stackName;
          subnetOctet = 10;
          weight = 100;
          roles = {};
        };
        enableExternalConnectors = false;
        tunnels = {};
        instances.proxy = {};
        dependencies = {};
        domainNames = ["apex"];
        tunnelDomainNames = ["apex"];
      }
      // extra;
  in {
    platform = mkProfile "platform" {
      instances = {
        proxy = {};
        db = {};
      };
    };
    app = mkProfile "app" {
      dnsRouteDomains = ["~app.test"];
      instances = {
        proxy = {};
        web.endpoint = {
          project = "role-project";
          address = "10.20.0.10";
          weight = 70;
          nodeLabel = "role";
        };
      };
      dependencies.db.stack = "platform";
    };
  };
  stackSetRegistryFor = profile: {
    roles = {
      proxy = {
        host = "${profile.stackName}-proxy";
        octet = 10;
      };
      web = {
        host = "app-web";
        octet = 20;
      };
      db = {
        host = "platform-db";
        octet = 30;
      };
    };
    services = {
      proxy = {};
      web.app.ports.http.port = 8080;
      db.database.ports.main.port = 5432;
    };
    domains = {
      apex = [profile.domain];
      omitted = ["omitted.example.test"];
    };
    tunnelDomains = [];
    limits = {};
  };
  stackSet = import ../stack-set.nix {
    profiles = stackSetProfiles;
    registryFor = stackSetRegistryFor;
    mkRegistryArgs = {
      constructor,
      domains,
      profile,
      registry,
      roles,
      services,
      tunnelDomains,
    }: {
      inherit constructor domains roles services tunnelDomains;
      inherit
        (profile)
        activeEndpointGroup
        domain
        enableExternalConnectors
        endpointGroups
        env
        internalDomain
        stackName
        tunnels
        ;
      dnsRouteDomains = profile.dnsRouteDomains or ["~${profile.internalDomain}"];
      secretNamespace = "test";
      org = "test";
      limits = registry.limits;
      trustedCidrs = [];
      splitHorizonRole = "proxy";
      stackBaseArgs = {
        defaultUser = "test";
        defaultClientSecretsBasePath = "/secrets";
        defaultClientIdentitySuffix = "client.test";
        defaultServiceIdentitySuffix = "service.test";
        defaultPostgresUrl = "postgresql://postgres@db/test";
        defaultNatsUrl = "nats://nats";
      };
    };
    resolveDependencyEndpoint = {
      name,
      owner,
      ...
    }: {
      project = owner.stackName;
      address =
        if name == "db"
        then "10.30.0.30"
        else "10.30.0.40";
      weight = 80;
      nodeLabel = owner.stackName;
    };
    mkProjection = {
      dependencyRoles,
      ownedRoles,
      ...
    }: {
      fixture = {
        owned = builtins.attrNames ownedRoles;
        dependencies = builtins.attrNames dependencyRoles;
      };
    };
  };
  standardOutputs = flakeLib.standardOutputsFrom [system] {
    ${system} = outputs;
  };
in {
  lib-flake-nested-rust-package = assert toString nestedRustPackage.sourcePath == toString ../../../pkgs/examples/hello-rust/default.nix;
    pkgs.runCommand "lib-flake-nested-rust-package-test" {} ''
      touch "$out"
    '';
  lib-flake-stack-set = assert stackSet.app.fixture.owned == ["proxy" "web"];
  assert stackSet.app.fixture.dependencies == ["db"];
  assert builtins.attrNames stackSet.app.serviceRegistry.domains == ["apex"];
  assert stackSet.app.serviceRegistry.dns.routeDomains == ["~app.test"];
  assert (builtins.head stackSet.app.serviceRegistry.roles.web.endpoints.live).project == "role-project";
  assert (builtins.head stackSet.app.serviceRegistry.roles.web.endpoints.live).weight == 70;
  assert (builtins.head stackSet.app.serviceRegistry.roles.db.endpoints.live).project == "platform";
    pkgs.runCommand "lib-flake-stack-set-test" {} ''
      touch "$out"
    '';
  lib-flake-isolated = assert flakeLib.stacks == {};
  assert outputs.packages ? migration-manager;
  assert outputs.packages.migration-manager.meta.mainProgram == "migration-manager";
  assert nativeClientCaDefaultsStack.defaultCaCertContainerPath == "/run/secrets/test-ca.crt";
  assert nativeClientCaDefaultsStack.srv.defaultPostgresCaCertPath == "/etc/ssl/certs/test-ca.crt";
  assert nativeClientCaDefaultsStack.srv.defaultNatsCaCertPath == "/etc/ssl/certs/test-ca.crt";
  assert standardOutputs.packages.${system} ? migration-manager;
    pkgs.runCommand "lib-flake-isolated-test" {} ''
      touch "$out"
    '';
}
