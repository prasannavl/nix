{pkgs}: let
  root = ../../../..;
  system = pkgs.stdenv.hostPlatform.system;
  isolated = name: path:
    builtins.path {
      inherit name path;
    };

  coreSource = isolated "ab-core-phase10c" (root + "/ab/core");
  servicesSource = builtins.path {
    name = "ab-services-phase10c";
    path = root + "/ab/services";
    # The consumer needs the component, not its owners' test inputs.
    filter = path: type: type != "directory" || builtins.baseNameOf path != "tests";
  };
  fixtureSource = isolated "ab-external-services-fixture" (root + "/ab/tests/fixtures/external-services");

  fixture = import fixtureSource {
    abCoreSource = coreSource;
    abServicesSource = servicesSource;
    nixpkgsPath = pkgs.path;
    inherit system;
  };

  # Exercise the public constructors with caller-supplied CLI packages; never run the helpers.
  inherit (fixture.ab.services) kanidm stalwart;
  kanidmProbe = kanidm.mkApplyScript {
    name = "kanidm-probe";
    kanidmPackage = fixture.pkgs.hello;
    url = "https://auth.example.test";
  };
  stalwartProbe = stalwart.mkApplyScript {
    name = "stalwart-probe";
    cliPackage = fixture.pkgs.hello;
    configHostPath = "/fixture/config.json";
    dataDir = "/fixture/data";
    image = "fixture/stalwart:unused";
    planHostPath = "/fixture/plan.json";
  };

  machineConfig = fixture.machineIdSystem.config;
  stateDir = machineConfig.services.machine-id.stateDir;
  machineIdUnit = machineConfig.systemd.services.machine-id-runtime-hostname;
  nginxConfigFile = pkgs.writeText "external-services-nginx.conf" fixture.nginxConfig;
in
  assert fixture.core.name == "ab-core";
  assert fixture.servicesComponent.name == "ab-services";
  assert fixture.servicesComponent.dependencies
  == {
    required = ["core"];
    optional = [];
  };
  assert fixture.ab ? services;
  assert !(fixture.ab ? runtime);
  assert !(fixture.ab ? repo);
  assert !(builtins.hasAttr "abird-host-agent" fixture.pkgs);
  assert (builtins.functionArgs kanidm.mkApplyScript).kanidmPackage == false;
  assert (builtins.functionArgs stalwart.mkApplyScript).cliPackage == false;
  assert fixture.pkgs.lib.hasSuffix "/bin/kanidm-probe" (fixture.pkgs.lib.getExe kanidmProbe);
  assert fixture.pkgs.lib.hasSuffix "/bin/stalwart-probe" (fixture.pkgs.lib.getExe stalwartProbe);
  # Exercise a custom directory without freezing the fixture's spelling.
  assert stateDir != fixture.machineIdSystem.options.services.machine-id.stateDir.default;
  assert builtins.elem
  "d ${stateDir} 0700 root root -"
  machineConfig.systemd.tmpfiles.rules;
  assert builtins.all
  (key: !(fixture.pkgs.lib.hasPrefix "${stateDir}/" key.path))
  machineConfig.services.openssh.hostKeys;
  assert machineIdUnit.wantedBy
  == [
    "multi-user.target"
    "sysinit-reactivation.target"
  ];
  assert machineIdUnit.before == ["tailscaled.service"];
  assert fixture.nginxIngress.http.proxies.api.serverNames == ["api.example.test"];
  assert fixture.nginxIngress.http.proxies.api.rateLimit == null;
  assert fixture.pkgs.lib.hasInfix "server_name api.example.test;" fixture.nginxConfig;
  assert fixture.pkgs.lib.hasInfix "server 127.0.0.1:18080;" fixture.nginxConfig;
    pkgs.runCommand "abird-external-services-fixture" {
      nativeBuildInputs = [pkgs.ripgrep];
    } ''
      set -euo pipefail

      grep -F 'server_name api.example.test;' ${nginxConfigFile}
      grep -F 'server 127.0.0.1:18080;' ${nginxConfigFile}

      bash ${./audit-component-source.sh} ${servicesSource}

      if rg -n 'ab/(runtime|repo|stack)|hosts/|config/|lib/flake|overlays/|pkgs/' ${fixtureSource}; then
        echo "external services fixture reaches undeclared repository source" >&2
        exit 1
      fi

      touch "$out"
    ''
