{pkgs}: let
  root = ../../../..;
  system = pkgs.stdenv.hostPlatform.system;
  isolated = name: path:
    builtins.path {
      inherit name path;
    };

  coreSource = isolated "ab-core-phase10a" (root + "/ab/core");
  fixtureSource = isolated "ab-external-core-package-fixture" (root + "/ab/tests/fixtures/external-core-package");

  fixture = import fixtureSource {
    abCoreSource = coreSource;
    nixpkgsPath = pkgs.path;
    inherit system;
  };

  package = fixture.outputs.packages.default;
  module = fixture.outputs.nixosModules.default;
in
  assert fixture.core.name == "ab-core";
  assert !(fixture.ab ? runtime);
  assert !(fixture.ab ? services);
  assert !(fixture.ab ? repo);
  assert !(builtins.hasAttr "abird-host-agent" fixture.pkgs);
  assert package.pname == "external-core-python";
  assert package.passthru ? nixosModule;
  assert builtins.isAttrs package.passthru.nixosModule;
  assert package.passthru.nixosModule ? __boundModuleFactory;
  assert builtins.isFunction module;
  assert fixture.moduleProbe.package.drvPath == package.drvPath;
  assert fixture.moduleProbe.execStart == "${package}/bin/external-core-python";
  assert fixture.moduleProbe.registeredUnits
  == [
    {
      name = "external-core-python";
      scope = "system";
      unit = "external-core-python.service";
      user = null;
    }
  ];
    pkgs.runCommand "abird-external-core-package-fixture" {
      nativeBuildInputs = [pkgs.ripgrep];
    } ''
      set -euo pipefail

      test -x ${package}/bin/external-core-python
      test "$(${package}/bin/external-core-python)" = "external ab-core fixture"

      if rg -n 'ab/(runtime|services|repo|stack)|hosts/|config/|lib/flake' ${fixtureSource}; then
        echo "external core/package fixture reaches outside ab-core" >&2
        exit 1
      fi

      touch "$out"
    ''
