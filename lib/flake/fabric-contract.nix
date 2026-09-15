{
  access ? [],
  addressSpaces,
  enabledFamilies,
  fabrics,
  preferredServiceFamily,
  roles,
  schemaVersion ? 1,
}: let
  unique = values:
    builtins.foldl' (
      result: value:
        if builtins.elem value result
        then result
        else result ++ [value]
    ) []
    values;
  familyAttrs = make:
    builtins.listToAttrs (
      map (family: {
        name = family;
        value = make family;
      })
      enabledFamilies
    );
  addressForPrefix = family: prefix: addressId:
    if family == "ipv4"
    then "${builtins.replaceStrings ["0/24"] [""] prefix}${toString addressId}"
    else if family == "ipv6"
    then "${builtins.replaceStrings ["::/64"] ["::"] prefix}${toString addressId}"
    else throw "Unsupported fabric address family ${family}";
  reservationForRole = fabric: role:
    builtins.filter (
      reservation: (reservation.role or null) == role
    ) (builtins.attrValues fabrics.${fabric}.reservations);
  roleAddressId = fabric: role:
    if builtins.elem role fabrics.${fabric}.memberRoles
    then roles.${role}.addressId
    else let
      reservations = reservationForRole fabric role;
    in
      if builtins.length reservations == 1
      then (builtins.head reservations).addressId
      else throw "Role ${role} is not assigned to fabric ${fabric}";
  addressForId = {
    addressId,
    fabric,
    family ? preferredServiceFamily,
  }:
    addressForPrefix family fabrics.${fabric}.prefixes.${family} addressId;
  addressFor = {
    fabric,
    role,
    family ? preferredServiceFamily,
  }:
    addressForId {
      addressId = roleAddressId fabric role;
      inherit fabric family;
    };
  addressSetForId = fabric: addressId:
    familyAttrs (family: addressForId {inherit addressId fabric family;});
  expandedFabrics =
    builtins.mapAttrs (
      fabric: definition:
        definition
        // {
          name = fabric;
          members = builtins.listToAttrs (
            map (role: {
              name = role;
              value = roles.${role} // {addresses = addressSetForId fabric roles.${role}.addressId;};
            })
            definition.memberRoles
          );
          reservations =
            builtins.mapAttrs (
              _name: reservation:
                reservation // {addresses = addressSetForId fabric reservation.addressId;}
            )
            definition.reservations;
        }
    )
    fabrics;
  expandedRoles =
    builtins.mapAttrs (
      role: definition:
        definition
        // {
          addresses = builtins.listToAttrs (
            map (fabric: {
              name = fabric;
              value = familyAttrs (family: addressFor {inherit fabric family role;});
            }) (
              builtins.filter (
                fabric:
                  builtins.elem role fabrics.${fabric}.memberRoles
                  || reservationForRole fabric role != []
              ) (builtins.attrNames fabrics)
            )
          );
        }
    )
    roles;
  selectorFor = selector: let
    fabric = selector.fabric;
    role = selector.role or null;
  in {
    inherit fabric role;
    project = fabrics.${fabric}.project;
    addresses = familyAttrs (
      family:
        if role == null
        then fabrics.${fabric}.prefixes.${family}
        else addressFor {inherit fabric family role;}
    );
  };
  expandAccess = edge:
    map (sourceFabric: let
      source = selectorFor ((builtins.removeAttrs edge.from ["fabrics"]) // {fabric = sourceFabric;});
      destination = selectorFor edge.to;
    in
      {
        id = "${edge.id}:${sourceFabric}";
        logicalEdge = edge.id;
        families = enabledFamilies;
        inherit source destination;
        from = source.project;
        to = destination.project;
        sourceAddress = source.addresses.${preferredServiceFamily};
        destinationAddress = destination.addresses.${preferredServiceFamily};
      }
      // (
        if edge ? tcp
        then {tcpPorts = edge.tcp;}
        else {}
      )
      // (
        if edge ? udp
        then {udpPorts = edge.udp;}
        else {}
      ))
    edge.from.fabrics;
  expandedAccess = builtins.concatMap expandAccess access;
  familyComplete = attrs: builtins.attrNames attrs == enabledFamilies;
  validAddressId = addressId: let
    parsed = builtins.tryEval (builtins.fromJSON (toString addressId));
  in
    parsed.success
    && builtins.isInt parsed.value
    && parsed.value >= 1
    && parsed.value <= 254;
  validPort = port:
    builtins.isInt port
    && port >= 1
    && port <= 65535;
  validPorts = edge:
    (edge ? tcp || edge ? udp)
    && builtins.isList (edge.tcp or [])
    && builtins.isList (edge.udp or [])
    && builtins.all validPort (edge.tcp or [])
    && builtins.all validPort (edge.udp or [])
    && builtins.length (unique (edge.tcp or [])) == builtins.length (edge.tcp or [])
    && builtins.length (unique (edge.udp or [])) == builtins.length (edge.udp or []);
  knownMembers = builtins.all (
    fabric:
      builtins.all (role: builtins.hasAttr role roles) fabric.memberRoles
  ) (builtins.attrValues fabrics);
  validReservations = builtins.all (
    fabric: let
      reservations = builtins.attrValues fabric.reservations;
      reservationRoles = map (reservation: reservation.role) (
        builtins.filter (reservation: reservation ? role) reservations
      );
    in
      builtins.all (reservation:
        validAddressId reservation.addressId
        && (!(reservation ? role) || builtins.hasAttr reservation.role roles))
      reservations
      && builtins.length (unique reservationRoles) == builtins.length reservationRoles
      && builtins.all (role: !builtins.elem role fabric.memberRoles) reservationRoles
  ) (builtins.attrValues fabrics);
  disjointAddressIds = builtins.all (
    fabric: let
      ids =
        map (role: toString roles.${role}.addressId) fabric.memberRoles
        ++ map (reservation: toString reservation.addressId) (builtins.attrValues fabric.reservations);
    in
      builtins.length (unique ids) == builtins.length ids
  ) (builtins.attrValues fabrics);
  knownAccessSelectors =
    builtins.all (
      edge:
        edge.from.fabrics
        != []
        && builtins.all (fabric: builtins.hasAttr fabric fabrics) edge.from.fabrics
        && builtins.hasAttr edge.to.fabric fabrics
        && (!(edge.from ? role) || builtins.all (fabric: (reservationForRole fabric edge.from.role != []) || builtins.elem edge.from.role fabrics.${fabric}.memberRoles) edge.from.fabrics)
        && (!(edge.to ? role) || (reservationForRole edge.to.fabric edge.to.role != []) || builtins.elem edge.to.role fabrics.${edge.to.fabric}.memberRoles)
        && validPorts edge
    )
    access;
  validPrefix = family: prefix:
    if family == "ipv4"
    then builtins.match "([0-9]{1,3}\\.){3}0/24" prefix != null
    else if family == "ipv6"
    then builtins.match "[0-9a-fA-F:]+::/64" prefix != null
    else false;
  fabricNames = builtins.attrNames fabrics;
  validation = {
    completeAddressSpaceFamilies = familyComplete addressSpaces;
    completeFabricFamilies = builtins.all (fabric: familyComplete fabric.prefixes) (builtins.attrValues fabrics);
    disjointAddressIds = disjointAddressIds;
    knownAccessSelectors = knownAccessSelectors;
    knownMembers = knownMembers;
    preferredFamilyEnabled = builtins.elem preferredServiceFamily enabledFamilies;
    supportedFamilies = builtins.all (family: builtins.elem family ["ipv4" "ipv6"]) enabledFamilies;
    uniqueAccessIds = let ids = map (rule: rule.id) expandedAccess; in builtins.length (unique ids) == builtins.length ids;
    uniqueFabricPrefixes = builtins.all (family: let
      prefixes = map (fabric: fabrics.${fabric}.prefixes.${family}) fabricNames;
    in
      builtins.length (unique prefixes) == builtins.length prefixes)
    enabledFamilies;
    uniqueLogicalEdgeIds = let ids = map (edge: edge.id) access; in builtins.length (unique ids) == builtins.length ids;
    validAddressSpaces =
      builtins.all (
        family: builtins.isString (addressSpaces.${family} or null)
      )
      enabledFamilies;
    validFabricPrefixes = builtins.all (fabric: builtins.all (family: validPrefix family fabric.prefixes.${family}) enabledFamilies) (builtins.attrValues fabrics);
    validMemberAddressIds = builtins.all (fabric: builtins.all (role: validAddressId roles.${role}.addressId) fabric.memberRoles) (builtins.attrValues fabrics);
    validReservations = validReservations;
  };
in
  if !builtins.all (value: value) (builtins.attrValues validation)
  then throw "Invalid fabric contract: ${builtins.toJSON (builtins.filter (name: !validation.${name}) (builtins.attrNames validation))}"
  else {
    inherit
      addressFor
      addressForId
      addressSpaces
      enabledFamilies
      preferredServiceFamily
      schemaVersion
      validation
      ;
    access = expandedAccess;
    fabrics = expandedFabrics;
    internalPrefixes = familyAttrs (family: map (fabric: fabrics.${fabric}.prefixes.${family}) fabricNames);
    logicalAccess = access;
    roles = expandedRoles;
  }
