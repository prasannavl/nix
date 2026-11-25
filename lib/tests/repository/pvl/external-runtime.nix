{pkgs}: let
  root = ../../../..;
  system = pkgs.stdenv.hostPlatform.system;
  isolated = name: path:
    builtins.path {
      inherit name path;
    };

  coreSource = isolated "ab-core-phase10b" (root + "/ab/core");
  runtimeSource = isolated "ab-runtime-phase10b" (root + "/ab/runtime");
  fixtureSource = isolated "ab-external-runtime-fixture" (root + "/ab/tests/fixtures/external-runtime");

  fixture = import fixtureSource {
    abCoreSource = coreSource;
    abRuntimeSource = runtimeSource;
    nixpkgsPath = pkgs.path;
    inherit system;
  };
in
  assert fixture.core.name == "ab-core";
  assert fixture.runtimeComponent.name == "ab-runtime";
  assert fixture.runtimeComponent.dependencies
  == {
    required = ["core"];
    optional = [];
  };
  assert fixture.ab ? runtime;
  assert !(fixture.ab ? services);
  assert !(fixture.ab ? repo);
  assert !(builtins.hasAttr "abird-host-agent" fixture.pkgs);
  assert fixture.wireguardPeer
  == {
    allowedIPs = ["10.88.0.2/32"];
    endpoint = "198.51.100.10:51820";
    persistentKeepalive = 25;
    publicKey = "fixture-public-key";
  };
  assert fixture.podmanFact.version == 2;
  assert fixture.podmanFact.backend == "compose";
  assert fixture.podmanFact.user == "root";
  assert fixture.podmanFact.ports
  == [
    {
      name = "http";
      port = 18080;
      protocols = ["tcp"];
    }
  ];
  assert !(fixture.podmanFact ? nginxRoutes);
  assert !(builtins.head fixture.podmanFact.ports ? nginxHostNames);
  assert !(builtins.head fixture.podmanFact.ports ? tunnels);
    pkgs.runCommand "abird-external-runtime-fixture" {
      nativeBuildInputs = [pkgs.ripgrep];
    } ''
      set -euo pipefail

      test -x ${fixture.wireguardHelper}/bin/wg-helper
      ${fixture.wireguardHelper}/bin/wg-helper --help | grep -F 'wg-helper health'

      bash ${./audit-component-source.sh} ${runtimeSource}

      if rg -n 'ab/(services|repo|stack)|hosts/|config/|lib/flake|overlays/|pkgs/' ${fixtureSource}; then
        echo "external runtime fixture reaches undeclared repository source" >&2
        exit 1
      fi

      touch "$out"
    ''
