{pkgs}: let
  mkStackDefinition = stackName: extra:
    {
      env = "test";
      domain = "${stackName}.example.test";
      internalDomain = "${stackName}.internal";
      activeEndpointGroup = "live";
      endpointGroups.live = {
        weight = 100;
      };
      enableExternalConnectors = false;
      tunnels = {};
      instances.proxy = {};
      dependencies = {};
      network = {
        project = stackName;
        subnetId = 10;
        priority = 100;
      };
    }
    // extra;
  stackDefinitions = {
    platform = mkStackDefinition "platform" {
      instances = {
        proxy = {};
        db = {};
      };
      network.subnetId = 30;
    };
    app = mkStackDefinition "app" {
      secretScope = "dev";
      stateVolumeSize = "32GiB";
      instances = {
        proxy = {};
        web = {};
      };
      dependencies.db.stack = "platform";
      access.database = {
        to = {
          stack = "platform";
          role = "db";
        };
        tcp = [5432];
      };
    };
  };
  registryFor = definition: {
    roles = {
      proxy = {
        host = "proxy";
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
    domains.apex = [definition.domain];
    tunnelDomains = [];
    limits = {};
  };
  baseDefaults = {
    fabric.addressBases = {
      ipv4 = "10.10";
      ipv6 = "fd42:1234:5678";
    };
    org = "test";
    identitySuffix = "service.test";
    postgres.url = "postgresql://postgres@db/test";
    nats.url = "nats://nats";
  };
  mkFamily = secrets:
    import ../configuration-family.nix {
      inherit stackDefinitions registryFor;
      placementScopes.app-live = {
        stack = "app";
        placement = "live";
      };
      defaults = baseDefaults // {inherit secrets;};
    };
  family = mkFamily {
    directory = "/secrets";
    labelRoot = "secrets";
  };
  invalidTrailingSecretDirectory = builtins.tryEval (builtins.deepSeq (mkFamily {
      directory = "/secrets/";
      labelRoot = "secrets";
    })
    true);
  rootSecretDirectoryFamily = mkFamily {
    directory = /.;
    labelRoot = "secrets";
  };
  invalidSecretNamespaceOverride = builtins.tryEval (import ../configuration-family.nix {
    inherit registryFor;
    stackDefinitions =
      stackDefinitions
      // {
        app = stackDefinitions.app // {secretNamespace = "shadow";};
      };
    defaults = {
      fabric.addressBases = {
        ipv4 = "10.10";
        ipv6 = "fd42:1234:5678";
      };
      org = "test";
      identitySuffix = "service.test";
      secrets = {
        directory = "/secrets";
        labelRoot = "secrets";
      };
    };
  });
  tryDefinitions = definitions:
    builtins.tryEval (builtins.deepSeq (import ../configuration-family.nix {
        inherit registryFor;
        stackDefinitions = definitions;
        defaults = {
          fabric.addressBases = {
            ipv4 = "10.10";
            ipv6 = "fd42:1234:5678";
          };
          org = "test";
          identitySuffix = "service.test";
          secrets = {
            directory = "/secrets";
            labelRoot = "secrets";
          };
        };
      })
      true);
  invalidSecretNamespace = builtins.tryEval (builtins.deepSeq (import ../configuration-family.nix {
      inherit stackDefinitions registryFor;
      defaults = {
        fabric.addressBases = {
          ipv4 = "10.10";
          ipv6 = "fd42:1234:5678";
        };
        org = "test";
        identitySuffix = "service.test";
        secrets = {
          namespace = "../escape";
          directory = "/secrets";
          labelRoot = "secrets";
        };
      };
    })
    true);
  tryDefaults = candidate:
    builtins.tryEval (builtins.deepSeq (import ../configuration-family.nix {
        inherit registryFor stackDefinitions;
        defaults = candidate;
      })
      true);
  invalidDefaultField = tryDefaults (baseDefaults
    // {
      secrets = {
        directory = "/secrets";
        labelRoot = "secrets";
      };
      postgress.url = "postgresql://typo";
    });
  invalidNestedDefaultField = tryDefaults (baseDefaults
    // {
      secrets = {
        directory = "/secrets";
        labelRoot = "secrets";
      };
      postgres = baseDefaults.postgres // {typo = true;};
    });
  invalidPlacementScopeField = builtins.tryEval (builtins.deepSeq (import ../configuration-family.nix {
      inherit registryFor stackDefinitions;
      defaults =
        baseDefaults
        // {
          secrets = {
            directory = "/secrets";
            labelRoot = "secrets";
          };
        };
      placementScopes.app-live = {
        stack = "app";
        placement = "live";
        typo = true;
      };
    })
    true);
  reservedDirectoryImport = builtins.tryEval (builtins.deepSeq ((import ../import-directory.nix) ../../../config) true);
  authoredStackName = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {stackName = "app";};});
  unknownDefinitionField = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {typo = true;};});
  invalidStateVolumeSize = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {stateVolumeSize = 32;};});
  invalidDomainNames = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {domainNames = ["missing"];};});
  overlappingRole = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {dependencies.web.stack = "platform";};});
  unknownRoleField = tryDefinitions (stackDefinitions // {app = stackDefinitions.app // {instances.web.typo = true;};});
  prebuiltConfigurationFamily = import ../prebuilt-configuration-family.nix {
    stacks.legacy.stackName = "legacy";
  };
  invalidPrebuiltConfigurationFamily = builtins.tryEval (import ../prebuilt-configuration-family.nix {
    stacks.legacy.stackName = "other";
  });
  inherit (family) stacks;
in
  assert builtins.attrNames stacks == ["app" "platform"];
  assert !invalidSecretNamespaceOverride.success;
  assert !authoredStackName.success;
  assert !unknownDefinitionField.success;
  assert !overlappingRole.success;
  assert !unknownRoleField.success;
  assert !invalidSecretNamespace.success;
  assert !invalidDefaultField.success;
  assert !invalidNestedDefaultField.success;
  assert !invalidPlacementScopeField.success;
  assert !reservedDirectoryImport.success;
  assert !invalidStateVolumeSize.success;
  assert !invalidDomainNames.success;
  assert !invalidTrailingSecretDirectory.success;
  assert prebuiltConfigurationFamily.stacks.legacy.stackName == "legacy";
  assert !invalidPrebuiltConfigurationFamily.success;
  assert stacks.app.stackName == "app";
  assert builtins.attrNames stacks.app.accounts == ["groupSets" "groups" "helpers" "meta" "nixosModule" "userSets" "users"];
  assert builtins.attrNames stacks.app.accounts.userSets == ["active" "activeIds" "disabled" "disabledIds"];
  assert builtins.attrNames stacks.app.accounts.groupSets == ["hasAnyGroup" "hasGroup" "members" "names" "namesForUserIds" "userIdsIn"];
  assert builtins.attrNames stacks.app.accounts.meta == ["defaultMailDomain" "includeAllStacks" "stackName"];
  assert builtins.isFunction stacks.app.accounts.nixosModule;
  assert stacks.app.accounts.helpers.isAccounts stacks.app.accounts;
  assert !(stacks.app.accounts.helpers.isAccounts (builtins.removeAttrs stacks.app.accounts ["meta"]));
  assert !(stacks.app ? users);
  assert family.projectionScopes.app-live
  == {
    stack = "app";
    placement = "live";
  };
  assert family.projections == {};
  assert stacks.app.secretNamespace == "test";
  assert stacks.app.secretScope == "dev";
  assert stacks.app.infrastructure.incus.stateVolumeSize == "32GiB";
  assert toString stacks.app.secrets.base == "/secrets/test";
  assert stacks.app.secrets.labelBase == "secrets/test";
  assert toString rootSecretDirectoryFamily.stacks.app.secrets.base == "/test";
  assert stacks.app.topology.dependencies.db.endpoint.addresses.ipv4 == "10.10.30.30";
  assert builtins.length stacks.app.infrastructure.incus.access == 1;
  assert builtins.all (rule: rule.source.fabric == "app" && rule.destination.fabric == "platform" && rule.tcpPorts == [5432]) stacks.app.infrastructure.incus.access;
  assert stacks.app.topology.dependencies.db.endpoint.addresses.ipv6 == "fd42:1234:5678:30::30";
  assert stacks.app.placements.live.infrastructure.incus.project == "app";
    pkgs.runCommand "configuration-family-test" {} ''
      touch "$out"
    ''
