{pkgs}: let
  projection = {
    addressBases = {
      ipv4 = "10.20";
      ipv6 = "fd42:20:20";
    };
    fabrics = {
      source = 1;
      destination = 2;
    };
    endpoints.app = 20;
    access.app = {
      from = {
        fabrics = ["source"];
        endpoint = "app";
      };
      to = {
        fabric = "destination";
        endpoint = "app";
      };
      tcp = [443];
    };
  };
  mkFabric = projection:
    import ../fabric-projection.nix {
      lib = pkgs.lib;
      projection = projection;
    };
  fabric = mkFabric projection;
  assertionsPass = candidate:
    pkgs.lib.all (entry: entry.assertion) candidate.assertions;
  duplicateSubnet = mkFabric (
    projection
    // {
      fabrics = projection.fabrics // {duplicate = projection.fabrics.source;};
    }
  );
  unknownAccessEndpoint = mkFabric (
    projection
    // {
      access =
        projection.access
        // {
          invalid = {
            from.fabrics = ["source"];
            to = {
              fabric = "destination";
              endpoint = "missing";
            };
            tcp = [443];
          };
        };
    }
  );
  groupedRule = {
    from = [
      {
        fabrics = ["source" "destination"];
        endpoint = "app";
      }
    ];
    to = [{fabrics = ["source" "destination"];}];
    tcp = [22];
    udp = [53];
  };
  withAccess = access: mkFabric (projection // {access = access;});
  grouped = withAccess {grouped = groupedRule;};
  explicit = withAccess (builtins.listToAttrs (builtins.concatMap (source:
    map (destination: {
      name = "${source}-${destination}";
      value = {
        from = {
          fabrics = [source];
          endpoint = "app";
        };
        to.fabric = destination;
        tcp = [22];
        udp = [53];
      };
    }) ["source" "destination"]) ["source" "destination"]));
  flows = f: builtins.sort builtins.lessThan (map builtins.toJSON f.forwardRules);
  rejectsRule = rule: let
    result = builtins.tryEval (builtins.deepSeq (withAccess {bad = rule;}).forwardRules (assertionsPass (withAccess {bad = rule;})));
  in
    !result.success || !result.value;
in
  assert assertionsPass grouped;
  assert flows grouped == flows explicit;
  assert builtins.length grouped.forwardRules == 8;
  assert rejectsRule (groupedRule // {from = [];});
  assert rejectsRule (groupedRule // {to = [];});
  assert rejectsRule (groupedRule // {from = [{fabrics = [];}];});
  assert rejectsRule (groupedRule
    // {
      to = [
        {
          fabric = "source";
          fabrics = ["destination"];
        }
      ];
    });
  assert rejectsRule (groupedRule // {to = [{fabrics = ["source" "source"];}];});
  assert rejectsRule (groupedRule // {to = groupedRule.to ++ groupedRule.to;});
  assert rejectsRule (groupedRule
    // {
      from = [
        {
          fabrics = ["source"];
          typo = "app";
        }
      ];
    });
  assert rejectsRule (groupedRule // {to.fabric = "unknown";});
  assert rejectsRule (groupedRule // {tcp = [0];});
  assert assertionsPass fabric;
  assert !assertionsPass duplicateSubnet;
  assert !assertionsPass unknownAccessEndpoint;
  assert fabric.enabledFamilies == ["ipv4" "ipv6"];
  assert fabric.prefixes.destination
  == {
    ipv4 = "10.20.2.0/24";
    ipv6 = "fd42:20:20:2::/64";
  };
  assert fabric.addressesFor "source" "app"
  == {
    ipv4 = "10.20.1.20";
    ipv6 = "fd42:20:20:1::20";
  };
  assert builtins.length fabric.forwardRules == 2;
  assert map (rule: rule.source) fabric.forwardRules
  == [
    "10.20.1.20"
    "fd42:20:20:1::20"
  ];
    pkgs.runCommand "lib-flake-fabric-projection-test" {} ''
      touch "$out"
    ''
