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
in
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
