{pkgs}: let
  mkContract = import ../fabric-contract.nix;
  mkFabricStack = import ../fabric-stack.nix;
  minimalContract = {
    addressSpaces = {
      ipv4 = "10.20.0.0/16";
      ipv6 = "fd42:20::/48";
    };
    enabledFamilies = ["ipv4" "ipv6"];
    preferredServiceFamily = "ipv4";
    roles.app = {
      addressId = "20";
      host = "app";
    };
    fabrics.app = {
      kind = "bridge";
      project = "app";
      prefixes = {
        ipv4 = "10.20.1.0/24";
        ipv6 = "fd42:20:0:1::/64";
      };
      memberRoles = ["app"];
      reservations = {};
    };
  };
  invalidFamilies = builtins.tryEval (mkContract (
    minimalContract
    // {addressSpaces.ipv6 = null;}
  ));
  duplicatePrefixes = builtins.tryEval (mkContract (
    minimalContract
    // {
      fabrics = minimalContract.fabrics // {copy = minimalContract.fabrics.app // {project = "copy";};};
    }
  ));
  conflictingReservationRole = builtins.tryEval (mkContract (
    minimalContract
    // {
      fabrics.app =
        minimalContract.fabrics.app
        // {
          reservations.duplicate = {
            addressId = "21";
            host = "other-app";
            role = "app";
          };
        };
    }
  ));
  minimalDefinitions.app = {
    stackName = "app";
    activeEndpointGroup = "live";
    network.subnetId = 1;
    instances.app = {};
    endpointGroups.live = {};
  };
  minimalRegistryFor = _definition: {
    roles.app = {
      host = "app";
      octet = 20;
    };
  };
  invalidMemberExclusion =
    builtins.tryEval
    (mkFabricStack {
      addressBases = {
        ipv4 = "10.20";
        ipv6 = "fd42:20:20";
      };
      definitions.app =
        minimalDefinitions.app
        // {
          network = minimalDefinitions.app.network // {members.exclude = ["missing"];};
        };
      registryFor = minimalRegistryFor;
    }).contract.validation;
  duplicateFabricName =
    builtins.tryEval
    (mkFabricStack {
      addressBases = {
        ipv4 = "10.20";
        ipv6 = "fd42:20:20";
      };
      definitions =
        minimalDefinitions
        // {
          copy =
            minimalDefinitions.app
            // {
              stackName = "copy";
              network = {
                name = "app";
                subnetId = 2;
              };
            };
        };
      registryFor = minimalRegistryFor;
    }).contract.validation;
  invalidAddressBase =
    builtins.tryEval
    (mkFabricStack {
      addressBases = {
        ipv4 = "10.999";
        ipv6 = "fd42:20:20";
      };
      definitions = minimalDefinitions;
      registryFor = minimalRegistryFor;
    }).contract.validation;
  invalidAccessPort = builtins.tryEval (mkContract (
    minimalContract
    // {
      access = [
        {
          id = "invalid-port";
          from.fabrics = ["app"];
          to.fabric = "app";
          tcp = [0];
        }
      ];
    }
  ));
  definitions = {
    app = {
      stackName = "app";
      activeEndpointGroup = "live";
      network = {
        subnetId = 1;
        priority = 10;
      };
      instances.app = {};
      endpointGroups = {
        live = {weight = 100;};
        cold = {
          weight = 0;
          network = {
            subnetId = 2;
            kind = "routed";
            routerHost = "test-router";
            members.exclude = ["app"];
            reservations.spare = {
              addressId = 21;
              role = "app";
              host = "spare-app";
            };
          };
        };
      };
      dependencies = {};
      access.self = {
        from = {
          endpointGroups = ["live" "cold"];
          role = "app";
        };
        to = {
          stack = "app";
          role = "app";
        };
        tcp = [443];
      };
      access.whole = {
        from.role = "app";
        to = {
          stack = "app";
          endpointGroup = "cold";
        };
        tcp = [22];
      };
    };
  };
  fabricStack = mkFabricStack {
    addressBases = {
      ipv4 = "10.20";
      ipv6 = "fd42:20:20";
    };
    inherit definitions;
    registryFor = _definition: {
      roles =
        (minimalRegistryFor {}).roles
        // {
          unassigned = {
            host = "unassigned";
            octet = 30;
          };
        };
    };
  };
  contract = fabricStack.contract;
  endpoints = fabricStack.endpointGroupsFor definitions.app;
  dependency = fabricStack.resolveDependencyEndpoint {
    declaration = {
      stack = "app";
      endpointGroup = "cold";
    };
    name = "app";
    definition = definitions.app;
  };
  projection = fabricStack.mkProjection {
    dependencyRoles = {};
    ownedRoles.app = {host = "app";};
    definition = definitions.app;
  };
  withAccess = rules:
    (mkFabricStack {
      addressBases = {
        ipv4 = "10.20";
        ipv6 = "fd42:20:20";
      };
      definitions.app = definitions.app // {access = rules;};
      registryFor = minimalRegistryFor;
    }).contract;
  groupedRule = {
    from = [
      {
        endpointGroup = "live";
        role = "app";
      }
      {
        endpointGroup = "cold";
        role = "app";
      }
    ];
    to = [
      {
        stack = "app";
        endpointGroups = ["live" "cold"];
      }
    ];
    tcp = [22];
    udp = [53];
  };
  grouped = withAccess {grouped = groupedRule;};
  explicit = withAccess (builtins.listToAttrs (builtins.concatMap (source:
    map (destination: {
      name = "${source}-${destination}";
      value = {
        from = {
          endpointGroups = [source];
          role = "app";
        };
        to = {
          stack = "app";
          endpointGroup = destination;
        };
        tcp = [22];
        udp = [53];
      };
    }) ["live" "cold"]) ["live" "cold"]));
  flows = c: builtins.sort builtins.lessThan (map (edge: builtins.toJSON (builtins.removeAttrs edge ["id" "logicalEdge"])) c.access);
  ids = c: builtins.sort builtins.lessThan (map (edge: edge.id) c.access);
  reordered = withAccess {
    grouped =
      groupedRule
      // {
        from = pkgs.lib.reverseList groupedRule.from;
        to = [
          {
            stack = "app";
            endpointGroups = ["cold" "live"];
          }
        ];
      };
  };
  rejectsRule = rule: !(builtins.tryEval (builtins.deepSeq (withAccess {bad = rule;}) true)).success;
in
  assert flows grouped == flows explicit;
  assert builtins.length grouped.access == 4;
  assert ids grouped == ids reordered;
  assert (builtins.head contract.access).id == "self:app";
  assert rejectsRule (groupedRule // {from = [];});
  assert rejectsRule (groupedRule // {to = [];});
  assert rejectsRule (groupedRule // {to = [{stack = "missing";}];});
  assert rejectsRule (groupedRule // {to = [{stack = [];}];});
  assert rejectsRule (groupedRule // {from = [1];});
  assert rejectsRule (groupedRule // {from = [{endpointGroups = [];}];});
  assert rejectsRule (groupedRule // {from = [{endpointGroups = ["live" "live"];}];});
  assert rejectsRule (groupedRule
    // {
      from = [
        {
          endpointGroup = "live";
          endpointGroups = ["cold"];
        }
      ];
    });
  assert rejectsRule (groupedRule
    // {
      to = [
        {
          stack = "app";
          endpointGroups = ["missing"];
        }
      ];
    });
  assert rejectsRule (groupedRule
    // {
      to = [
        {
          stack = "app";
          endpointGroup = "live";
          endpointGroups = ["cold"];
        }
      ];
    });
  assert rejectsRule (groupedRule // {from = [{role = "missing";}];});
  assert rejectsRule (groupedRule
    // {
      from = [
        {
          role = "app";
          typo = true;
        }
      ];
    });
  assert rejectsRule (groupedRule // {from = groupedRule.from ++ groupedRule.from;});
  assert rejectsRule (groupedRule // {to = groupedRule.to ++ groupedRule.to;});
  assert builtins.all (value: value) (builtins.attrValues contract.validation);
  assert !invalidFamilies.success;
  assert !duplicatePrefixes.success;
  assert !conflictingReservationRole.success;
  assert !invalidMemberExclusion.success;
  assert !duplicateFabricName.success;
  assert !invalidAddressBase.success;
  assert !invalidAccessPort.success;
  assert contract.addressSpaces
  == {
    ipv4 = "10.20.0.0/16";
    ipv6 = "fd42:20:20::/48";
  };
  assert contract.fabrics.app.members.app.addresses.ipv6 == "fd42:20:20:1::20";
  assert contract.fabrics.app-cold.members == {};
  assert contract.fabrics.app-cold.reservations.spare.addresses.ipv4 == "10.20.2.21";
  assert endpoints.cold.roles.app.host == "spare-app";
  assert endpoints.cold.roles.app.address == "10.20.2.21";
  assert contract.fabrics.app-cold.kind == "routed";
  assert contract.fabrics.app-cold.routerHost == "test-router";
  assert !(builtins.tryEval (contract.addressFor {
    fabric = "app-cold";
    family = "ipv6";
    role = "unassigned";
  })).success;
  assert builtins.length contract.access == 3;
  assert (builtins.elemAt contract.access 2).destination.role == null;
  assert (builtins.elemAt contract.access 2).destination.addresses
  == {
    ipv4 = "10.20.2.0/24";
    ipv6 = "fd42:20:20:2::/64";
  };
  assert builtins.all (
    access:
      builtins.attrNames access.source.addresses
      == contract.enabledFamilies
      && builtins.attrNames access.destination.addresses == contract.enabledFamilies
  )
  contract.access;
  assert (builtins.elemAt contract.access 1).source.addresses.ipv6 == "fd42:20:20:2::21";
  assert (builtins.head contract.access).destination.addresses.ipv4 == "10.20.1.20";
  assert dependency.address == "10.20.2.21";
  assert dependency.prefixes.ipv6 == "fd42:20:20:2::/64";
  assert projection.infrastructure.incus.instances.app.address == "10.20.1.20";
  assert projection.infrastructure.incus.instances.app.addresses.ipv6 == "fd42:20:20:1::20";
  assert projection.infrastructure.incus.instances.app.resourceId == "app.app";
  assert projection.infrastructure.incus.priority == 10;
    pkgs.runCommand "lib-flake-fabric-contract-test" {} ''
      touch "$out"
    ''
