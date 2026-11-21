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
  flakeLib = import ../../../nix/default.nix {
    inputs = {};
    nixpkgs = {lib = pkgs.lib;};
    flake-utils = fakeFlakeUtils;
    overlays = [];
    stacks = {};
  };
  manifest = import ../../../pkgs/manifest.nix;
  outputs = flakeLib.withPkgs pkgs;
  packageOutputs = (import ../../../nix/repo-context.nix {inherit pkgs;}).repo.packages;
  abCore = import ../../../ab/core;
  abStack = import ../../../ab/stack {core = abCore;};
  ab = abCore.mk {
    inherit pkgs;
    projectRoot = ../../..;
    treefmtConfig = ../../../treefmt.toml;
  };
  packageHelper = import ../../../ab/core/packaging/pkg-helper.nix {
    projectRoot = ../../..;
    treefmtConfig = ../../../treefmt.toml;
  };
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
  nativeClientCaDefaultsStack = abStack.mkBase {
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
    rawUserdata = {};
    rawGroupData = {};
  };
  clientIdentityModuleProbe = outputs.nixosModules.clientIdentity {
    config.environment.systemPackages = [outputs.packages.nats-wrecking-ball];
    lib = pkgs.lib;
    stack = nativeClientCaDefaultsStack;
  };
  genericNatsStreamsExtension = {
    extraConfig = _service: _cfg: {};
  };
  fakeNatsCli = pkgs.writeShellApplication {
    name = "nats";
    text = ''
      printf '%s\n' "$*" >>"$FAKE_NATS_TRACE"
      if [[ "$*" == *"server check connection"* ]]; then
        exit 0
      fi
      if [[ "$*" == *"stream ls"* ]]; then
        case "''${FAKE_NATS_MODE:-converged}" in
          absent) printf '%s\n' 'null' ;;
          converged | drift | info-error) printf '%s\n' '["test-stream"]' ;;
          lookup-error)
            echo "nats: error: authorization violation" >&2
            exit 1
            ;;
          malformed-list) printf '%s\n' '{"unexpected":true}' ;;
        esac
        exit 0
      fi
      if [[ "$*" == *"stream info"* ]]; then
        case "''${FAKE_NATS_MODE:-converged}" in
          converged)
            printf '%s\n' '{"config":{"subjects":["test.subject"],"storage":"file","retention":"workqueue","max_consumers":1}}'
            ;;
          drift)
            printf '%s\n' '{"config":{"subjects":["old.subject"],"storage":"file","retention":"limits","max_consumers":2}}'
            ;;
          info-error)
            echo "nats: error: stream disappeared after listing" >&2
            exit 1
            ;;
        esac
        exit 0
      fi
      if [[ "$*" == *"stream add"* ]]; then
        exit 0
      fi
      exit 1
    '';
  };
  testNatsPkgs = pkgs // {natscli = fakeNatsCli;};
  testNatsAb = abCore.mk {
    pkgs = testNatsPkgs;
    projectRoot = ../../..;
    treefmtConfig = ../../../treefmt.toml;
  };
  genericNatsStreams = pkgs.callPackage ../../../pkgs/support/nats-streams/default.nix {
    inherit ab;
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
  runtimeNatsStreams =
    (import ../../../pkgs/support/nats-streams/default.nix {
      pkgs = testNatsPkgs;
      ab = testNatsAb;
    }).passthru.mkStreamSet {
      serviceName = "runtime-test-nats-streams";
      streams = [
        {
          stream = "test-stream";
          subject = "test.subject";
        }
      ];
    };
  genericNatsStreamsModule = genericNatsStreams.passthru.nixosModule;
  firstNatsStreamsModule = firstNatsStreamSet.passthru.nixosModule;
  secondNatsStreamsModule = secondNatsStreamSet.passthru.nixosModule;
  natsStreamSetsSystem = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit pkgs system;
    specialArgs = {
      abNixosUser = nativeClientCaDefaultsStack.service.user;
      abNixosPolicy = {
        identityFor = serviceName:
          nativeClientCaDefaultsStack.identity.mk {
            name = serviceName;
            suffix = nativeClientCaDefaultsStack.identity.serviceSuffix;
          };
        nats = nativeClientCaDefaultsStack.nats;
        postgres = nativeClientCaDefaultsStack.postgres;
      };
    };
    modules = [
      ab.nixos.registryModule
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
  stackDefinitions = let
    mkStackDefinition = stackName: extra:
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
        ingress.edgeTlsDomainNames = ["apex"];
        tunnels = {};
        instances.proxy = {};
        dependencies = {};
        domainNames = ["apex"];
        tunnelDomainNames = ["apex"];
      }
      // extra;
  in {
    platform = mkStackDefinition "platform" {
      instances = {
        proxy = {};
        db = {};
      };
    };
    app = mkStackDefinition "app" {
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
  registryForDefinition = definition: {
    roles = {
      proxy = {
        host = "${definition.stackName}-proxy";
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
      apex = [definition.domain];
      omitted = ["omitted.example.test"];
    };
    tunnelDomains = [];
    limits = {};
  };
  stackSet = abStack.buildSet {
    definitions = stackDefinitions;
    registryFor = registryForDefinition;
    mkRegistryArgs = {
      constructor,
      domains,
      definition,
      registry,
      roles,
      services,
      tunnelDomains,
    }: {
      inherit constructor domains roles services tunnelDomains;
      inherit
        (definition)
        activeEndpointGroup
        domain
        enableExternalConnectors
        endpointGroups
        env
        internalDomain
        stackName
        tunnels
        ;
      dnsRouteDomains = definition.dnsRouteDomains or ["~${definition.internalDomain}"];
      ingress = definition.ingress or {};
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
        rawUserdata = {};
        rawGroupData = {};
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
in
  {
    lib-flake-language-toolchains = import ./language-toolchains.nix {inherit pkgs;};
    lib-flake-nix-cache-policy = import ./nix-cache-policy.nix {inherit pkgs;};
    lib-flake-fabric-contract = import ../../../ab/stack/tests/fabric-contract.nix {inherit pkgs;};
    lib-flake-fabric-projection = import ./fabric-projection.nix {inherit pkgs;};
    lib-flake-phase-projection = import ./phase-projection.nix {inherit pkgs;};
    lib-flake-repo-modules = import ./repo-modules.nix {inherit pkgs;};
    lib-flake-service-client-endpoints = import ../../../ab/stack/tests/service-client-endpoints.nix {inherit pkgs;};
    lib-flake-service-placements = import ./service-placements.nix {inherit pkgs;};
    lib-flake-runtime-projection-closeouts = import ./runtime-projection-closeouts.nix {inherit pkgs;};
    lib-flake-service-moves = import ./service-moves.nix {inherit pkgs;};
    lib-flake-projection-domain-fold = import ./projection-domain-fold.nix {inherit pkgs;};
    lib-flake-repository-fold = import ../../../ab/repo/tests/repository-fold.nix {inherit pkgs;};
    lib-flake-config-family = import ./config-family.nix {inherit pkgs;};
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
        export FAKE_NATS_TRACE="$PWD/nats.trace"

        : >"$FAKE_NATS_TRACE"
        export FAKE_NATS_MODE=converged
        ${pkgs.lib.getExe runtimeNatsStreams} nats ca cert key >converged.log
        grep -F "stream already converged: test-stream (test.subject)" converged.log
        if grep -F "stream add" "$FAKE_NATS_TRACE"; then
          echo "converged stream unexpectedly attempted creation" >&2
          exit 1
        fi

        : >"$FAKE_NATS_TRACE"
        export FAKE_NATS_MODE=absent
        ${pkgs.lib.getExe runtimeNatsStreams} nats ca cert key
        grep -F "stream add test-stream" "$FAKE_NATS_TRACE"

        : >"$FAKE_NATS_TRACE"
        export FAKE_NATS_MODE=drift
        if ${pkgs.lib.getExe runtimeNatsStreams} nats ca cert key >drift.log 2>&1; then
          echo "drifted stream unexpectedly converged" >&2
          exit 1
        fi
        grep -F "stream configuration drift: test-stream" drift.log
        grep -F '"subjects":["old.subject"]' drift.log
        grep -F "refusing to mutate an existing stream" drift.log
        if grep -F "stream add" "$FAKE_NATS_TRACE"; then
          echo "drifted stream unexpectedly attempted creation" >&2
          exit 1
        fi

        : >"$FAKE_NATS_TRACE"
        export FAKE_NATS_MODE=lookup-error
        if ${pkgs.lib.getExe runtimeNatsStreams} nats ca cert key >lookup-error.log 2>&1; then
          echo "failed stream lookup unexpectedly converged" >&2
          exit 1
        fi
        grep -F "stream listing failed while checking: test-stream" lookup-error.log
        grep -F "refusing to create a stream whose absence was not established" lookup-error.log
        if grep -F "stream add" "$FAKE_NATS_TRACE"; then
          echo "failed lookup unexpectedly attempted creation" >&2
          exit 1
        fi

        : >"$FAKE_NATS_TRACE"
        export FAKE_NATS_MODE=info-error
        if ${pkgs.lib.getExe runtimeNatsStreams} nats ca cert key >info-error.log 2>&1; then
          echo "failed stream info unexpectedly converged" >&2
          exit 1
        fi
        grep -F "stream info failed after listing: test-stream" info-error.log
        grep -F "refusing to mutate or recreate a stream" info-error.log
        if grep -F "stream add" "$FAKE_NATS_TRACE"; then
          echo "failed stream info unexpectedly attempted creation" >&2
          exit 1
        fi

        : >"$FAKE_NATS_TRACE"
        export FAKE_NATS_MODE=malformed-list
        if ${pkgs.lib.getExe runtimeNatsStreams} nats ca cert key >malformed-list.log 2>&1; then
          echo "malformed stream listing unexpectedly converged" >&2
          exit 1
        fi
        grep -F "stream listing returned an unexpected JSON shape" malformed-list.log
        if grep -F "stream add" "$FAKE_NATS_TRACE"; then
          echo "malformed stream listing unexpectedly attempted creation" >&2
          exit 1
        fi
        touch "$out"
      '';
    lib-flake-stack-set = assert stackSet.app.fixture.owned == ["proxy" "web" "worker"];
    assert stackSet.app.fixture.dependencies == ["db"];
    assert builtins.attrNames stackSet.app.serviceRegistry.domains == ["apex"];
    assert stackSet.app.serviceRegistry.dns.routeDomains == ["~app.test"];
    assert stackSet.app.ingress.edgeTls.hosts == ["app.example.test"];
    assert stackSet.app.ingress.internalTls.clientCidrs
    == {
      ipv4 = ["10.30.0.0/16"];
      ipv6 = ["fd42:30::/48"];
    };
    assert !(stackSet.app.serviceRegistry ? tunnelHosts);
    assert stackSet.app.tunnels.hosts == ["app.example.test"];
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
    assert !(stackSet.app.topology ? network);
    assert !(stackSet.app ? enableExternalConnectors);
    assert stackSet.app.network == {externalConnectors = false;};
    assert remappedAppStack.serviceRegistry.roleForService "app" == "proxy";
    assert builtins.attrNames remappedAppStack == builtins.attrNames stackSet.app;
    assert !(remappedAppStack ? enableExternalConnectors);
    assert remappedAppStack.serviceRegistry.upstreamForService "app" "http" == "10.10.10.10:8080";
      pkgs.runCommand "lib-flake-stack-build-set-test" {} ''
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
    assert outputs.packages.nats-wrecking-ball.identityIntent == {name = "nats-wrecking-ball";};
    assert outputs.packages.nats-wrecking-ball.flakeExtraNixosModules ? clientIdentity;
    assert builtins.isFunction outputs.nixosModules.clientIdentity;
    assert clientIdentityModuleProbe.age.secrets._type == "if";
    assert clientIdentityModuleProbe.age.secrets.condition;
    assert clientIdentityModuleProbe.age.secrets.content == {};
    assert outputs.apps.cloudflare-apps-deploy.program == "${outputs.packages.cloudflare-apps.deploy}/bin/cloudflare-apps-deploy";
    assert packageOutputs.stdPackages."cloudflare-apps/llmug-hello".drvPath == packageOutputs.packages.cloudflare-apps.llmug-hello.drvPath;
    assert !(flakeLib ? serviceModule);
    assert !(flakeLib ? serviceModuleFactory);
    assert !(nativeClientCaDefaultsStack ? srv);
    assert builtins.attrNames nativeClientCaDefaultsStack.identity
    == [
      "bind"
      "clientSuffix"
      "externalServiceSuffix"
      "mk"
      "nats"
      "postgres"
      "serviceCertFileName"
      "serviceHost"
      "serviceKeyFileName"
      "serviceSuffix"
      "serviceUser"
      "vectorAgent"
      "vectorHub"
      "vmstack"
    ];
    assert nativeClientCaDefaultsStack.domains
    == {
      public = "example.test";
      internal = "test.internal";
    };
    assert nativeClientCaDefaultsStack.mail.domain == "example.test";
    assert nativeClientCaDefaultsStack.mail.noReplyFor "probe" == "no-reply+probe@example.test";
    assert builtins.all (name: !(builtins.hasAttr name nativeClientCaDefaultsStack)) [
      "org"
      "defaultMailDomain"
      "publicDomain"
      "internalDomain"
      "noReplyEmailFor"
    ];
    assert nativeClientCaDefaultsStack.service == {user = "svc";};
    assert nativeClientCaDefaultsStack.secrets.namespace == "test";
    assert nativeClientCaDefaultsStack.secrets.scope == null;
    assert builtins.all (name: !(builtins.hasAttr name nativeClientCaDefaultsStack)) [
      "secretNamespace"
      "secretScope"
      "defaultNginxSecretsBase"
      "defaultNginxSecretsBasePath"
    ];
    assert nativeClientCaDefaultsStack.secrets.defaults
    == {
      owner = "svc";
      group = "svc";
      mode = "0400";
    };
    assert nativeClientCaDefaultsStack.secrets.ageSecret "/fixture.age" {mode = "0440";}
    == {
      file = "/fixture.age";
      owner = "svc";
      group = "svc";
      mode = "0440";
    };
    assert nativeClientCaDefaultsStack.secrets.tracked "/does/not/exist" "fixture-secret" == null;
    assert nativeClientCaDefaultsStack.certs
    == {
      ca = {
        basePath = null;
        sourceFile = null;
        ageFile = "/secrets/client/ca/ca.crt.age";
        hostPath = "/etc/ssl/certs/test-ca.crt";
        containerPath = "/run/secrets/test-ca.crt";
        file = "/etc/ssl/certs/test-ca.crt";
        sourceHashFile = null;
        mountPath = "/run/secrets/test-ca.crt";
      };
      bundle = {
        hostPath = "/etc/ssl/certs/test-ca-bundle.crt";
        containerPath = "/run/secrets/test-ca-bundle.crt";
        file = "/etc/ssl/certs/test-ca-bundle.crt";
        sourceHashFile = null;
        mountPath = "/run/secrets/test-ca-bundle.crt";
      };
    };
    assert builtins.all (name: !(builtins.hasAttr name nativeClientCaDefaultsStack)) [
      "defaultCaCertBasePath"
      "defaultCaCertFile"
      "defaultCaCertAgeFile"
      "defaultCaCertHostPath"
      "defaultCaCertContainerPath"
      "defaultCaBundleHostPath"
      "defaultCaBundleContainerPath"
      "defaultCaCertificate"
      "defaultCaBundleCertificate"
    ];
    assert nativeClientCaDefaultsStack.postgres
    == {
      url = "postgresql://postgres@db:5432/app?sslmode=verify-ca";
      caCertPath = "/etc/ssl/certs/test-ca.crt";
      after = [];
    };
    assert nativeClientCaDefaultsStack.nats
    == {
      url = "tls://nats:4222";
      caCertPath = "/etc/ssl/certs/test-ca.crt";
      after = [];
    };
    assert !(standardOutputs.packages.${system} ? migration-manager);
    assert standardOutputs.apps.${system} ? abird-host-manager;
      pkgs.runCommand "lib-flake-isolated-test" {} ''
        touch "$out"
      '';
  }
  // import ../../../ab/core/packaging/rust/tests {pkgs = pkgs;}
