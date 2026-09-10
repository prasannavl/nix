{pkgs}: let
  projection = import ../../../hosts/pvl-x2/abird-fabric.nix;
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
      fabrics = projection.fabrics // {abird-dev = projection.fabrics.abird;};
    }
  );
  unknownAccessEndpoint = mkFabric (
    projection
    // {
      access =
        projection.access
        // {
          invalid = {
            from.fabrics = ["abird"];
            to = {
              fabric = "abird-platform";
              endpoint = "missing";
            };
            tcp = [443];
          };
        };
    }
  );
  oauthRules =
    builtins.filter (
      rule:
        rule.from
        == "abird-gondor"
        && rule.to == "abird-platform"
        && (rule.tcpPorts or []) == [18444]
    )
    fabric.forwardRules;
in
  assert assertionsPass fabric;
  assert !assertionsPass duplicateSubnet;
  assert !assertionsPass unknownAccessEndpoint;
  assert fabric.enabledFamilies == ["ipv4" "ipv6"];
  assert fabric.prefixes.abird-gondor
  == {
    ipv4 = "10.10.30.0/24";
    ipv6 = "fd42:ab1d:ab1d:30::/64";
  };
  assert fabric.addressesFor "abird-platform" "nest"
  == {
    ipv4 = "10.10.0.10";
    ipv6 = "fd42:ab1d:ab1d:0::10";
  };
  assert builtins.length fabric.forwardRules == 14;
  assert map (rule: rule.source) oauthRules
  == [
    "10.10.30.20"
    "fd42:ab1d:ab1d:30::20"
  ];
    pkgs.runCommand "lib-flake-fabric-projection-test" {} ''
      touch "$out"
    ''
