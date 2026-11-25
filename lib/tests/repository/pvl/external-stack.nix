{pkgs}: let
  root = ../../../..;
  system = pkgs.stdenv.hostPlatform.system;
  isolated = name: path:
    builtins.path {
      inherit name path;
    };

  coreSource = isolated "ab-core-phase10e" (root + "/ab/core");
  stackSource = isolated "ab-stack-phase10e" (root + "/ab/stack");
  fixtureSource = isolated "ab-external-stack-fixture" (root + "/ab/tests/fixtures/external-stack");

  fixture = import fixtureSource {
    abCoreSource = coreSource;
    abStackSource = stackSource;
    nixpkgsPath = pkgs.path;
    inherit system;
  };

  stack = fixture.stack;
  baseStack = fixture.baseStack;
  tunnelEndpoints = fixture.stackComponent.tunnels.endpointsFromInstances "external-stack" {
    api.exposedPorts.http = {
      port = 18080;
      upstreamProtocol = "http";
      tunnels = [
        {
          kind = "cloudflare";
          hostNames = ["api.example.test"];
        }
      ];
    };
  };
in
  assert fixture.core.name == "ab-core";
  assert fixture.stackComponent.name == "ab-stack";
  assert fixture.stackComponent.dependencies
  == {
    required = ["core"];
    optional = [];
  };
  assert builtins.functionArgs fixture.stackComponent.mk
  == {
    definition = false;
  };
  assert builtins.functionArgs fixture.stackComponent.accounts.mk
  == {
    defaultMailDomain = false;
    includeAllStacks = true;
    rawGroupData = false;
    rawUserdata = false;
    stackName = false;
  };
  assert builtins.functionArgs fixture.stackComponent.mkBase
  == {
    defaultCaBundleContainerPath = true;
    defaultCaBundleHostPath = true;
    defaultCaCertAgeFile = true;
    defaultCaCertBasePath = true;
    defaultCaCertContainerPath = true;
    defaultCaCertFile = true;
    defaultCaCertHostPath = true;
    defaultClientIdentitySuffix = false;
    defaultClientSecretsBasePath = false;
    defaultExtServiceIdentitySuffix = true;
    defaultMailDomain = false;
    defaultNatsAfter = true;
    defaultNatsCaCertPath = true;
    defaultNatsSecretsBasePath = true;
    defaultNatsUrl = false;
    defaultNginxSecretsBasePath = true;
    defaultPostgresAfter = true;
    defaultPostgresCaCertPath = true;
    defaultPostgresSecretsBasePath = true;
    defaultPostgresUrl = false;
    defaultSecretGroup = true;
    defaultSecretMode = true;
    defaultSecretOwner = true;
    defaultServiceIdentitySuffix = false;
    defaultUser = false;
    defaultVmstackSecretsBasePath = true;
    env = false;
    internalDomain = true;
    org = false;
    publicDomain = true;
    rawGroupData = false;
    rawUserdata = false;
    secretNamespace = true;
    secretScope = true;
    stackName = false;
    stackSecretsBasePath = true;
    stackSecretsLabel = true;
  };
  assert baseStack.name == "fixture-base";
  assert baseStack.environment == "test";
  assert baseStack.accounts.users.alice.email == "alice@example.test";
  assert baseStack.accounts.groups.users.users == ["alice"];
  assert builtins.attrNames fixture.stackComponent.fabric == ["access" "contract" "incus" "mk" "projection"];
  assert builtins.attrNames fixture.stackComponent.config == ["family" "prebuiltFamily"];
  assert builtins.attrNames fixture.stackComponent.phase == ["ingressProfiles" "projection" "routeProfiles"];
  assert builtins.functionArgs fixture.stackComponent.fabric.incus == {lib = false;};
  assert builtins.attrNames (fixture.stackComponent.fabric.incus {lib = pkgs.lib;}).fabricPolicyProfiles
  == ["contained" "containedPublic" "isolated" "isolatedPublic" "open" "quarantine"];
  assert fixture.stackComponent.tunnels.kinds == ["cloudflare" "rathole"];
  assert tunnelEndpoints
  == [
    {
      hostName = "api.example.test";
      kind = "cloudflare";
      name = "api.example.test";
      portName = "http";
      remotePort = null;
      service = "http://127.0.0.1:18080";
      serviceName = "api";
      stackName = "external-stack";
      targetPort = 18080;
    }
  ];
  assert fixture.stackComponent.tunnels.ingressFromEndpoints "cloudflare" tunnelEndpoints
  == {"api.example.test" = "http://127.0.0.1:18080";};
  assert stack.name == "external-stack";
  assert stack.environment == "test";
  assert stack.domains.public == "example.test";
  assert stack.domains.internal == "example.internal";
  assert stack.topology.instances.api
  == {
    role = "app";
    host = "fixture-host";
  };
  assert stack.network
  == {
    project = "external-stack";
    externalConnectors = false;
  };
  assert stack.tunnels
  == {
    ingress = {};
    publications = {};
  };
  assert builtins.attrNames stack.ingress.http
  == [
    "proxies"
    "redirects"
    "routes"
    "staticSites"
  ];
  assert stack.ingress.http.proxies.api.serverNames == ["api.example.test"];
  assert stack.ingress.http.proxies.api.port == 18080;
  assert stack.ingress.http.routes.health.serverName == "api.example.test";
  assert stack.ingress.http.redirects == {};
  assert stack.ingress.http.staticSites == {};
  assert stack.ingress.stream.proxies.smtp.listenPort == 2525;
  assert fixture.stackComponent.ingress.hasHttpEntries stack.ingress;
  assert !(fixture.ab ? runtime);
  assert !(fixture.ab ? services);
  assert !(fixture.ab ? repo);
  assert !(builtins.hasAttr "abird-host-agent" fixture.pkgs);
    pkgs.runCommand "abird-external-stack-fixture" {
      nativeBuildInputs = [pkgs.ripgrep];
    } ''
      set -euo pipefail

      bash ${./audit-component-source.sh} ${stackSource}

      if rg -n 'ab/(runtime|services|repo)|hosts/|config/|lib/flake|overlays/|pkgs/' ${fixtureSource}; then
        echo "external stack fixture reaches undeclared repository source" >&2
        exit 1
      fi

      touch "$out"
    ''
