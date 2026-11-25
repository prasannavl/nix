{pkgs}: let
  root = ../../../..;
  system = pkgs.stdenv.hostPlatform.system;
  isolated = name: path:
    builtins.path {
      inherit name path;
    };

  coreSource = isolated "ab-core-phase10a" (root + "/ab/core");
  stackSource = isolated "ab-stack-phase10f" (root + "/ab/stack");
  externalPackageSource =
    isolated
    "ab-external-core-package-fixture"
    (root + "/ab/tests/fixtures/external-core-package");

  external = import externalPackageSource {
    abCoreSource = coreSource;
    nixpkgsPath = pkgs.path;
    inherit system;
  };

  plainPkgs = external.pkgs;
  core = import coreSource;
  ab = core.mk {pkgs = plainPkgs;};
  stackComponent = import stackSource {inherit core;};

  stack = stackComponent.mk {
    definition = {
      name = "z-external-consumption";
      environment = "test";

      service.user = "deployer";

      topology.instances.external-core-python = {
        role = "app";
        host = "fixture-host";
      };

      ingress.http.proxies.external-core-python = {
        serverNames = ["external.example.test"];
        port = 18080;
        upstreams = ["127.0.0.1:18080"];
      };
    };
  };

  externalPackage = external.outputs.packages.default;
  externalPackageConstructor = import (externalPackageSource + "/package.nix");

  deploymentModule = ab.nixos.service {
    package = externalPackage;
    user = stack.service.user;
    name = "external-core-python";
    serviceDescription = "Z-integrated external core fixture";
  };

  deployedSystem = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    pkgs = plainPkgs;
    inherit system;

    specialArgs = {
      inherit stack;
      abNixosUser = stack.service.user;
    };

    modules = [
      deploymentModule
      {
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "/dev/null";
          fsType = "ext4";
        };

        users.users.deployer = {
          isNormalUser = true;
          home = "/home/deployer";
        };

        user-services.deployer.external-core-python.enable = true;
      }
    ];
  };

  deployedPackage =
    deployedSystem.config.user-services.deployer.external-core-python.package;
  deployedUnit =
    deployedSystem.config.systemd.user.services.deployer-external-core-python;
in
  assert builtins.functionArgs externalPackageConstructor
  == {
    ab = false;
    pkgs = false;
  };
  assert externalPackage.drvPath == external.moduleProbe.package.drvPath;
  assert stack.name == "z-external-consumption";
  assert stack.service.user == "deployer";
  assert stack.topology.instances.external-core-python
  == {
    role = "app";
    host = "fixture-host";
  };
  assert stack.ingress.http.proxies.external-core-python.serverNames
  == ["external.example.test"];
  assert deployedPackage.drvPath == externalPackage.drvPath;
  assert deployedUnit.serviceConfig.ExecStart
  == "${externalPackage}/bin/external-core-python";
  assert deployedUnit.unitConfig.ConditionUser == "deployer";
  assert deployedSystem.config._ab.nixos.registeredUnits
  == [
    {
      name = "deployer:external-core-python";
      scope = "user";
      unit = "deployer-external-core-python.service";
      user = "deployer";
    }
  ];
    pkgs.runCommand "abird-external-z-consumption" {
      nativeBuildInputs = [pkgs.ripgrep];
    } ''
      set -euo pipefail

      test -x ${externalPackage}/bin/external-core-python
      test "$(${externalPackage}/bin/external-core-python)" = "external ab-core fixture"

      if rg -n '(^|[,{[:space:]])stack([,}[:space:]]|$)' ${externalPackageSource}/package.nix; then
        echo "external package constructor acquired stack input" >&2
        exit 1
      fi

      touch "$out"
    ''
