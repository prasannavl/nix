{
  addressBases,
  profiles,
  registryFor,
  preferredServiceFamily ? "ipv4",
}: let
  unique = values:
    builtins.foldl' (
      result: value:
        if builtins.elem value result
        then result
        else result ++ [value]
    ) []
    values;
  checkedAttrs = context: allowed: attrs: let
    unknown = builtins.filter (name: !builtins.elem name allowed) (builtins.attrNames attrs);
  in
    if unknown == []
    then attrs
    else throw "Unknown ${context} attributes: ${builtins.toJSON unknown}";
  validSubnetId = value: let
    parsed = builtins.tryEval (builtins.fromJSON (toString value));
  in
    parsed.success
    && builtins.isInt parsed.value
    && parsed.value >= 0
    && parsed.value <= 255;
  validIpv4Part = value: let
    parsed = builtins.tryEval (builtins.fromJSON value);
  in
    parsed.success
    && builtins.isInt parsed.value
    && parsed.value >= 0
    && parsed.value <= 255;
  validAddressBase = family: base:
    builtins.isString base
    && (
      if family == "ipv4"
      then let
        parts = builtins.match "([0-9]{1,3})\\.([0-9]{1,3})" base;
      in
        parts != null && builtins.all validIpv4Part parts
      else if family == "ipv6"
      then builtins.match "([0-9a-fA-F]{1,4}:){2}[0-9a-fA-F]{1,4}" base != null
      else false
    );
  enabledFamilies = builtins.attrNames addressBases;
  validAddressBases =
    enabledFamilies
    != []
    && builtins.all (family: validAddressBase family addressBases.${family}) enabledFamilies;
  familyAttrs = make:
    builtins.listToAttrs (
      map (family: {
        name = family;
        value = make family;
      })
      enabledFamilies
    );
  addressSpaces = familyAttrs (
    family:
      if family == "ipv4"
      then "${addressBases.ipv4}.0.0/16"
      else if family == "ipv6"
      then "${addressBases.ipv6}::/48"
      else throw "Unsupported fabric address family ${family}"
  );
  prefixFor = family: subnetId:
    if family == "ipv4"
    then "${addressBases.ipv4}.${toString subnetId}.0/24"
    else if family == "ipv6"
    then "${addressBases.ipv6}:${toString subnetId}::/64"
    else throw "Unsupported fabric address family ${family}";

  profileNames = builtins.attrNames profiles;
  firstProfile =
    if profileNames == []
    then throw "A fabric stack requires at least one profile"
    else profiles.${builtins.head profileNames};
  roleDefinitionsFor = profile:
    builtins.mapAttrs (_role: spec: {
      addressId = toString spec.octet;
      host = spec.host;
    })
    (registryFor profile).roles;
  roles = roleDefinitionsFor firstProfile;
  consistentRoleDefinitions = builtins.all (
    profile: roleDefinitionsFor profile == roles
  ) (builtins.attrValues profiles);

  primaryFabricName = profile: profile.network.name or profile.stackName;
  endpointFabricName = profile: group:
    if profile.endpointGroups.${group} ? network
    then profile.endpointGroups.${group}.network.name or "${profile.stackName}-${group}"
    else primaryFabricName profile;
  endpointMetadata = endpoint: builtins.removeAttrs endpoint ["network"];
  primaryEndpoint = profile:
    builtins.removeAttrs profile.network [
      "kind"
      "members"
      "name"
      "project"
      "reservations"
      "routerHost"
      "state"
      "subnetId"
    ]
    // {fabric = primaryFabricName profile;};
  endpointDeclaration = profile: group:
    endpointMetadata profile.endpointGroups.${group}
    // {fabric = endpointFabricName profile group;};

  memberRolesFor = profile: definition: let
    defaults = builtins.attrNames profile.instances;
    members = checkedAttrs "fabric members" ["exclude" "include"] (definition.members or {});
    include = members.include or [];
    exclude = members.exclude or [];
    unknownExclusions = builtins.filter (role: !builtins.elem role defaults) exclude;
  in
    if unknownExclusions != []
    then throw "Fabric member exclusions are not stack instances: ${builtins.toJSON unknownExclusions}"
    else unique (builtins.filter (role: !builtins.elem role exclude) defaults ++ include);
  normalizeReservation = name: rawReservation: let
    reservation =
      checkedAttrs "fabric reservation ${name}" [
        "addressId"
        "host"
        "role"
        "state"
      ] (
        if builtins.isAttrs rawReservation
        then rawReservation
        else {addressId = rawReservation;}
      );
  in
    reservation
    // {
      addressId = toString reservation.addressId;
      host = reservation.host or name;
    };
  normalizeFabric = profile: rawDefinition: let
    definition =
      checkedAttrs "fabric network" [
        "kind"
        "members"
        "name"
        "nodeLabel"
        "priority"
        "project"
        "reservations"
        "routerHost"
        "state"
        "subnetId"
      ]
      rawDefinition;
  in
    if !validSubnetId (definition.subnetId or null)
    then throw "Fabric subnetId must be an integer from 0 through 255"
    else
      {
        kind = definition.kind or "bridge";
        project = definition.project or profile.stackName;
        prefixes = familyAttrs (family: prefixFor family definition.subnetId);
        memberRoles = memberRolesFor profile definition;
        reservations = builtins.mapAttrs normalizeReservation (definition.reservations or {});
      }
      // (
        if definition ? routerHost
        then {routerHost = definition.routerHost;}
        else {}
      )
      // (
        if definition ? state
        then {state = definition.state;}
        else {}
      );
  fabricEntries =
    builtins.concatMap (
      profileName: let
        profile = profiles.${profileName};
        primaryName = primaryFabricName profile;
        networkGroups = builtins.filter (
          group: profile.endpointGroups.${group} ? network
        ) (builtins.attrNames profile.endpointGroups);
      in
        [
          {
            name = primaryName;
            value = normalizeFabric profile profile.network;
          }
        ]
        ++ map (group: {
          name = endpointFabricName profile group;
          value = normalizeFabric profile profile.endpointGroups.${group}.network;
        })
        networkGroups
    )
    profileNames;
  fabricNames = map (entry: entry.name) fabricEntries;
  fabrics =
    if builtins.length (unique fabricNames) != builtins.length fabricNames
    then throw "Fabric names must be unique: ${builtins.toJSON fabricNames}"
    else builtins.listToAttrs fabricEntries;

  fabricForGroup = profile: group:
    if !builtins.hasAttr group profile.endpointGroups
    then throw "Unknown endpoint group ${profile.stackName}.${group}"
    else endpointFabricName profile group;
  normalizeAccess = profile: id: rawDeclaration: let
    declaration = checkedAttrs "fabric access rule ${id}" ["from" "tcp" "to" "udp"] rawDeclaration;
    source = checkedAttrs "fabric access source ${id}" ["endpointGroups" "role"] (declaration.from or {});
    destination = checkedAttrs "fabric access destination ${id}" ["endpointGroup" "role" "stack"] declaration.to;
    sourceGroups = source.endpointGroups or [profile.activeEndpointGroup];
    destinationProfile = profiles.${destination.stack};
    destinationGroup = destination.endpointGroup or destinationProfile.activeEndpointGroup;
  in
    {
      inherit id;
      from =
        {
          fabrics = map (fabricForGroup profile) sourceGroups;
        }
        // (
          if source ? role
          then {role = source.role;}
          else {}
        );
      to =
        {
          fabric = fabricForGroup destinationProfile destinationGroup;
        }
        // (
          if destination ? role
          then {role = destination.role;}
          else {}
        );
    }
    // (
      if declaration ? tcp
      then {tcp = declaration.tcp;}
      else {}
    )
    // (
      if declaration ? udp
      then {udp = declaration.udp;}
      else {}
    );
  access =
    builtins.concatMap (
      profileName: let
        profile = profiles.${profileName};
      in
        map (
          id: normalizeAccess profile id profile.access.${id}
        ) (builtins.attrNames (profile.access or {}))
    )
    profileNames;

  contract =
    if !validAddressBases
    then throw "Fabric address bases must describe valid IPv4 /16 or IPv6 /48 spaces"
    else if !consistentRoleDefinitions
    then throw "Fabric stack profiles must share role host and address definitions"
    else
      import ./fabric-contract.nix {
        inherit
          access
          addressSpaces
          enabledFamilies
          fabrics
          preferredServiceFamily
          roles
          ;
      };
  fabricFor = name:
    contract.fabrics.${name}
    // {
      fabric = name;
    };
  hydrateEndpoint = endpoint:
    fabricFor endpoint.fabric
    // endpoint
    // {
      project = endpoint.project or contract.fabrics.${endpoint.fabric}.project;
      prefixes = contract.fabrics.${endpoint.fabric}.prefixes;
    };
  endpointFor = profile: endpointGroup:
    hydrateEndpoint (
      if endpointGroup == null
      then primaryEndpoint profile
      else endpointDeclaration profile endpointGroup
    );
  endpointRoleSpecs = endpoint: let
    fabric = contract.fabrics.${endpoint.fabric};
    members =
      builtins.mapAttrs (_role: member: {
        address = member.addresses.${contract.preferredServiceFamily};
        addresses = member.addresses;
      })
      fabric.members;
    reservations = builtins.listToAttrs (
      map (reservation: {
        name = reservation.role;
        value = {
          address = reservation.addresses.${contract.preferredServiceFamily};
          addresses = reservation.addresses;
          host = reservation.host;
        };
      }) (
        builtins.filter (reservation: reservation ? role) (builtins.attrValues fabric.reservations)
      )
    );
  in
    members // reservations;
in rec {
  inherit contract;

  endpointGroupsFor = profile:
    builtins.mapAttrs (group: _endpoint: let
      hydrated = endpointFor profile group;
    in
      hydrated // {roles = endpointRoleSpecs hydrated;})
    profile.endpointGroups;

  resolveDependencyEndpoint = {
    declaration,
    name,
    profile,
    ...
  }: let
    placement =
      if declaration ? placement
      then {stack = profile.stackName;} // declaration.placement
      else {stack = declaration.stack;};
    placementProfile = profiles.${placement.stack};
    placementGroup = placement.endpointGroup or declaration.endpointGroup or placementProfile.activeEndpointGroup;
    base = endpointFor placementProfile placementGroup;
    endpoint = hydrateEndpoint (base // (declaration.endpoint or {}));
  in
    {
      address = contract.addressFor {
        fabric = endpoint.fabric;
        family = contract.preferredServiceFamily;
        role = name;
      };
      addresses = builtins.listToAttrs (
        map (family: {
          name = family;
          value = contract.addressFor {
            inherit family;
            fabric = endpoint.fabric;
            role = name;
          };
        })
        contract.enabledFamilies
      );
      inherit (endpoint) fabric prefixes project;
      nodeLabel = endpoint.nodeLabel or placementGroup;
    }
    // (declaration.endpoint or {});

  mkProjection = {
    dependencyRoles,
    ownedRoles,
    profile,
    ...
  }: let
    network = endpointFor profile null;
    fabric = network.fabric;
    addressForFamily = family: role:
      contract.addressFor {inherit fabric family role;};
    addressFor = addressForFamily contract.preferredServiceFamily;
    resourceIdFor = role: "${network.project}.${ownedRoles.${role}.host}";
    instances = builtins.mapAttrs (role: spec:
      spec
      // {
        inherit role;
        address = addressFor role;
        addresses = builtins.listToAttrs (
          map (family: {
            name = family;
            value = addressForFamily family role;
          })
          contract.enabledFamilies
        );
        resourceId = resourceIdFor role;
      })
    ownedRoles;
  in {
    topology = {
      inherit network instances;
      dependencies = builtins.mapAttrs (
        role: declaration:
          declaration // {inherit (dependencyRoles.${role}) endpoint;}
      ) (profile.dependencies or {});
    };
    infrastructure.incus = {
      inherit addressFor addressForFamily fabric instances resourceIdFor;
      access = builtins.filter (rule: rule.source.fabric == fabric) contract.access;
      allowedSubnets = network.prefixes;
      enabledFamilies = contract.enabledFamilies;
      preferredServiceFamily = contract.preferredServiceFamily;
      prefixes = network.prefixes;
      priority = network.priority;
      project = network.project;
      stateVolumeSize = profile.stateVolumeSize or null;
    };
  };
}
