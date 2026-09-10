{
  lib,
  projection,
}: let
  inherit (projection) access addressBases endpoints fabrics;
  enabledFamilies = builtins.attrNames addressBases;
  fabricNames = builtins.attrNames fabrics;
  endpointNames = builtins.attrNames endpoints;
  supportedFamilies = ["ipv4" "ipv6"];
  unique = values: builtins.length (lib.unique values) == builtins.length values;
  validId = minimum: maximum: value:
    builtins.isInt value && value >= minimum && value <= maximum;
  validIpv4Part = part: let
    parsed = builtins.tryEval (builtins.fromJSON part);
  in
    parsed.success && validId 0 255 parsed.value;
  validAddressBase = family: base:
    builtins.isString base
    && (
      if family == "ipv4"
      then let parts = lib.splitString "." base; in builtins.length parts == 2 && lib.all validIpv4Part parts
      else if family == "ipv6"
      then builtins.match "([0-9a-fA-F]{1,4}:){2}[0-9a-fA-F]{1,4}" base != null
      else false
    );
  validPort = validId 1 65535;
  validPorts = edge:
    (edge ? tcp || edge ? udp)
    && builtins.isList (edge.tcp or [])
    && builtins.isList (edge.udp or [])
    && lib.all validPort (edge.tcp or [])
    && lib.all validPort (edge.udp or [])
    && unique (edge.tcp or [])
    && unique (edge.udp or []);
  knownEndpoint = selector:
    !(selector ? endpoint)
    || (
      builtins.isString selector.endpoint
      && builtins.hasAttr selector.endpoint endpoints
    );
  validEdge = edge:
    edge ? from
    && builtins.isAttrs edge.from
    && edge.from ? fabrics
    && builtins.isList edge.from.fabrics
    && edge.from.fabrics != []
    && unique edge.from.fabrics
    && lib.all builtins.isString edge.from.fabrics
    && lib.all (fabric: builtins.hasAttr fabric fabrics) edge.from.fabrics
    && knownEndpoint edge.from
    && edge ? to
    && builtins.isAttrs edge.to
    && edge.to ? fabric
    && builtins.isString edge.to.fabric
    && builtins.hasAttr edge.to.fabric fabrics
    && knownEndpoint edge.to
    && validPorts edge;
  prefixLength = {
    ipv4 = 24;
    ipv6 = 64;
  };
  addressForId = fabric: family: addressId:
    if family == "ipv4"
    then "${addressBases.ipv4}.${toString fabrics.${fabric}}.${toString addressId}"
    else if family == "ipv6"
    then "${addressBases.ipv6}:${toString fabrics.${fabric}}::${toString addressId}"
    else throw "Unsupported fabric address family ${family}";
  prefixFor = fabric: family:
    if family == "ipv4"
    then "${addressBases.ipv4}.${toString fabrics.${fabric}}.0/24"
    else if family == "ipv6"
    then "${addressBases.ipv6}:${toString fabrics.${fabric}}::/64"
    else throw "Unsupported fabric address family ${family}";
  prefixes =
    builtins.mapAttrs (
      fabric: _subnetId:
        builtins.mapAttrs (family: _base: prefixFor fabric family) addressBases
    )
    fabrics;
  addressesFor = fabric: endpoint:
    builtins.mapAttrs (
      family: _base: addressForId fabric family endpoints.${endpoint}
    )
    addressBases;
  selectorAddress = selector: fabric: family:
    if selector ? endpoint
    then addressForId fabric family endpoints.${selector.endpoint}
    else prefixes.${fabric}.${family};
  expandEdge = _name: edge:
    builtins.concatMap (
      sourceFabric:
        map (
          family:
            {
              from = sourceFabric;
              to = edge.to.fabric;
              destination = selectorAddress edge.to edge.to.fabric family;
            }
            // lib.optionalAttrs (edge.from ? endpoint) {
              source = selectorAddress edge.from sourceFabric family;
            }
            // lib.optionalAttrs (edge ? tcp) {tcpPorts = edge.tcp;}
            // lib.optionalAttrs (edge ? udp) {udpPorts = edge.udp;}
        )
        enabledFamilies
    )
    edge.from.fabrics;
  forwardRules = builtins.concatLists (lib.mapAttrsToList expandEdge access);
in {
  inherit
    addressForId
    addressesFor
    enabledFamilies
    fabricNames
    forwardRules
    prefixLength
    prefixes
    ;

  assertions = [
    {
      assertion =
        enabledFamilies
        != []
        && lib.all (family: builtins.elem family supportedFamilies) enabledFamilies;
      message = "Fabric projection address bases must use ipv4, ipv6, or both";
    }
    {
      assertion = lib.all (family: validAddressBase family addressBases.${family}) enabledFamilies;
      message = "Fabric projection IPv4 /16 and IPv6 /48 address bases must be valid";
    }
    {
      assertion =
        lib.all (validId 0 255) (builtins.attrValues fabrics)
        && unique (builtins.attrValues fabrics);
      message = "Fabric projection subnet IDs must be unique integers from 0 through 255";
    }
    {
      assertion =
        lib.all (validId 1 254) (builtins.attrValues endpoints)
        && unique (builtins.attrValues endpoints);
      message = "Fabric projection endpoint IDs must be unique integers from 1 through 254";
    }
    {
      assertion = fabricNames != [] && endpointNames != [];
      message = "Fabric projection must declare at least one fabric and endpoint";
    }
    {
      assertion = lib.all validEdge (builtins.attrValues access);
      message = "Fabric projection access edges must use unique known sources, known endpoints, and valid unique ports";
    }
  ];
}
