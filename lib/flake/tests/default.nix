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
  manifest = import ../../../pkgs/manifest.nix;
  outputs = flakeLib.withPkgs pkgs;
  packageOutputs = import ../packages.nix {inherit pkgs;};
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
  genericNatsStreamsExtension = {
    extraConfig = _service: _cfg: {};
  };
  genericNatsStreams = pkgs.callPackage ../../../pkgs/support/nats-streams/default.nix {
    stack = nativeClientCaDefaultsStack;
  };
  firstNatsStreamSet = genericNatsStreams.passthru.mkStreamSet {
    serviceName = "test-nats-streams";
    clientServiceName = "test-nats-client";
    envPrefix = "TEST_NATS_STREAMS";
    packageDescription = "Test NATS stream reconciliation";
    streams = [
      {
        stream = "test-stream";
        subject = "test.subject";
      }
    ];
    serviceParts = [genericNatsStreamsExtension];
  };
  secondNatsStreamSet = genericNatsStreams.passthru.mkStreamSet {
    serviceName = "other-nats-streams";
    clientServiceName = "other-nats-client";
    envPrefix = "OTHER_NATS_STREAMS";
    packageDescription = "Other NATS stream reconciliation";
    streams = [
      {
        stream = "other-stream";
        subject = "other.subject";
      }
    ];
  };
  genericNatsStreamsModule = genericNatsStreams.passthru.nixosModule;
  firstNatsStreamsModule = firstNatsStreamSet.passthru.nixosModule;
  secondNatsStreamsModule = secondNatsStreamSet.passthru.nixosModule;
  natsStreamSetsSystem = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit pkgs system;
    modules = [
      nativeClientCaDefaultsStack.srv.portCheckModule
      ({lib, ...}: {
        options.age.secrets = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          default = {};
        };
      })
      firstNatsStreamsModule
      secondNatsStreamsModule
    ];
  };
  stackSetProfiles = let
    mkProfile = stackName: extra:
      {
        inherit stackName;
        env = "test";
        domain = "${stackName}.example.test";
        internalDomain = "${stackName}.internal";
        activeEndpointGroup = "live";
        endpointGroups = {
          live = {
            project = stackName;
            subnetOctet = 10;
            weight = 100;
            roles = {};
          };
          cold = {
            project = "${stackName}-cold";
            subnetOctet = 11;
            weight = 0;
            memberRoles = ["proxy"];
            roles.proxy = {};
          };
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
        worker = {};
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
      worker = {
        host = "app-worker";
        octet = 40;
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
      trustedCidrs = ["10.30.0.0/16" "fd42:30::/48"];
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
  remappedAppStack = stackSet.app.withServiceRoles {app = "proxy";};
  standardOutputs = flakeLib.standardOutputsFrom [system] {
    ${system} = outputs;
  };
in {
  lib-flake-fabric-contract = import ./fabric-contract.nix {inherit pkgs;};
  lib-flake-fabric-projection = import ./fabric-projection.nix {inherit pkgs;};
  lib-flake-phase-projection = import ./phase-projection.nix {inherit pkgs;};
  lib-flake-repo-modules = import ./repo-modules.nix {inherit pkgs;};
  lib-flake-service-client-endpoints = import ./service-client-endpoints.nix {inherit pkgs;};
  lib-flake-service-placements = import ./service-placements.nix {inherit pkgs;};
  lib-flake-service-moves = import ./service-moves.nix {inherit pkgs;};
  lib-flake-nested-rust-package = assert toString nestedRustPackage.sourcePath == toString ../../../pkgs/examples/hello-rust/default.nix;
    pkgs.runCommand "lib-flake-nested-rust-package-test" {} ''
      touch "$out"
    '';
  lib-flake-nats-streams-seams = assert genericNatsStreams.meta.mainProgram == "nats-streams";
  assert genericNatsStreams.meta.description == "Ensure configured NATS JetStream streams exist";
  assert genericNatsStreamsModule.__moduleArgs.name == "nats-streams";
  assert genericNatsStreamsModule.__moduleArgs.envPrefix == "NATS_STREAMS";
  assert toString genericNatsStreamsModule.__moduleSourcePath == toString ../../../pkgs/support/nats-streams/default.nix;
  assert firstNatsStreamSet.meta.mainProgram == "test-nats-streams";
  assert firstNatsStreamSet.meta.description == "Test NATS stream reconciliation";
  assert builtins.isFunction firstNatsStreamsModule;
  assert firstNatsStreamSet.passthru.streamSet.serviceName == "test-nats-streams";
  assert firstNatsStreamSet.passthru.streamSet.clientServiceName == "test-nats-client";
  assert firstNatsStreamSet.passthru.streamSet.envPrefix == "TEST_NATS_STREAMS";
  assert firstNatsStreamSet.passthru.streamSet.servicePartCount == 1;
  assert firstNatsStreamSet.passthru.streamSet.streams
  == [
    {
      stream = "test-stream";
      subject = "test.subject";
    }
  ];
  assert secondNatsStreamSet.meta.mainProgram == "other-nats-streams";
  assert secondNatsStreamSet.meta.description == "Other NATS stream reconciliation";
  assert builtins.isFunction secondNatsStreamsModule;
  assert secondNatsStreamSet.passthru.streamSet.serviceName == "other-nats-streams";
  assert secondNatsStreamSet.passthru.streamSet.clientServiceName == "other-nats-client";
  assert secondNatsStreamSet.passthru.streamSet.envPrefix == "OTHER_NATS_STREAMS";
  assert secondNatsStreamSet.passthru.streamSet.servicePartCount == 0;
  assert secondNatsStreamSet.passthru.streamSet.streams
  == [
    {
      stream = "other-stream";
      subject = "other.subject";
    }
  ];
  assert natsStreamSetsSystem.config.user-services.svc.test-nats-streams.package.meta.mainProgram == "test-nats-streams";
  assert natsStreamSetsSystem.config.user-services.svc.other-nats-streams.package.meta.mainProgram == "other-nats-streams";
    pkgs.runCommand "lib-flake-nats-streams-seams-test" {} ''
      touch "$out"
    '';
  lib-flake-stack-set = assert stackSet.app.fixture.owned == ["proxy" "web" "worker"];
  assert stackSet.app.fixture.dependencies == ["db"];
  assert builtins.attrNames stackSet.app.serviceRegistry.domains == ["apex"];
  assert stackSet.app.serviceRegistry.dns.routeDomains == ["~app.test"];
  assert stackSet.app.serviceRegistry.dns.trustedCidrsByFamily
  == {
    ipv4 = ["10.30.0.0/16"];
    ipv6 = ["fd42:30::/48"];
  };
  assert stackSet.app.serviceRegistry.dns.loopbackCidrsByFamily
  == {
    ipv4 = ["127.0.0.0/8"];
    ipv6 = ["::1/128"];
  };
  assert (builtins.head stackSet.app.serviceRegistry.roles.web.endpoints.live).project == "role-project";
  assert (builtins.head stackSet.app.serviceRegistry.roles.web.endpoints.live).weight == 70;
  assert (builtins.head stackSet.app.serviceRegistry.roles.db.endpoints.live).project == "platform";
  assert stackSet.app.serviceRegistry.roles.db.endpoints ? cold;
  assert !(stackSet.app.serviceRegistry.roles.worker.endpoints ? cold);
  assert stackSet.app.serviceRegistry.roleForService "app" == "web";
  assert remappedAppStack.serviceRegistry.roleForService "app" == "proxy";
  assert remappedAppStack.serviceRegistry.upstreamForService "app" "http" == "10.10.10.10:8080";
    pkgs.runCommand "lib-flake-stack-set-test" {} ''
      touch "$out"
    '';
  lib-flake-isolated = assert flakeLib.stacks == {};
  assert builtins.all (
    entry:
      builtins.isPath entry
      || (builtins.isAttrs entry && builtins.isPath entry.path)
  ) (builtins.attrValues manifest.packages);
  assert !(outputs.packages ? migration-manager);
  assert !(outputs.packages ? data-migrator);
  assert !(outputs.packages ? host-manager);
  assert outputs.packages.abird-host-agent.meta.mainProgram == "abird-host-agent";
  assert outputs.packages.abird-host-manager.meta.mainProgram == "abird-host-manager";
  assert outputs.apps.cloudflare-apps-deploy.program == "${outputs.packages.cloudflare-apps.deploy}/bin/cloudflare-apps-deploy";
  assert packageOutputs.stdPackages."cloudflare-apps/llmug-hello".drvPath == packageOutputs.packages.cloudflare-apps.llmug-hello.drvPath;
  assert nativeClientCaDefaultsStack.defaultCaCertContainerPath == "/run/secrets/test-ca.crt";
  assert nativeClientCaDefaultsStack.srv.defaultPostgresCaCertPath == "/etc/ssl/certs/test-ca.crt";
  assert nativeClientCaDefaultsStack.srv.defaultNatsCaCertPath == "/etc/ssl/certs/test-ca.crt";
  assert !(standardOutputs.packages.${system} ? migration-manager);
  assert standardOutputs.apps.${system} ? abird-host-manager;
    pkgs.runCommand "lib-flake-isolated-test" {} ''
      touch "$out"
    '';
}
