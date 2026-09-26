{
  addressBases,
  definitions,
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

  definitionNames = builtins.attrNames definitions;
  firstDefinition =
    if definitionNames == []
    then throw "A fabric stack requires at least one stack definition"
    else definitions.${builtins.head definitionNames};
  roleDefinitionsFor = definition:
    builtins.mapAttrs (_role: spec: {
      addressId = toString spec.octet;
      host = spec.host;
    })
    (registryFor definition).roles;
  roles = roleDefinitionsFor firstDefinition;
  consistentRoleDefinitions = builtins.all (
    definition: roleDefinitionsFor definition == roles
  ) (builtins.attrValues definitions);

  primaryFabricName = definition: definition.network.name or definition.stackName;
  endpointFabricName = definition: group:
    if definition.endpointGroups.${group} ? network
    then definition.endpointGroups.${group}.network.name or "${definition.stackName}-${group}"
    else primaryFabricName definition;
  endpointMetadata = endpoint: builtins.removeAttrs endpoint ["network"];
  primaryEndpoint = definition:
    builtins.removeAttrs definition.network [
      "kind"
      "members"
      "name"
      "project"
      "reservations"
      "routerHost"
      "state"
      "subnetId"
    ]
    // {fabric = primaryFabricName definition;};
  endpointDeclaration = definition: group:
    endpointMetadata definition.endpointGroups.${group}
    // {fabric = endpointFabricName definition group;};

  memberRolesFor = stackDefinition: fabricDefinition: let
    defaults = builtins.attrNames stackDefinition.instances;
    members = checkedAttrs "fabric members" ["exclude" "include"] (fabricDefinition.members or {});
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
  normalizeFabric = stackDefinition: rawDefinition: let
    fabricDefinition =
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
    if !validSubnetId (fabricDefinition.subnetId or null)
    then throw "Fabric subnetId must be an integer from 0 through 255"
    else
      {
        kind = fabricDefinition.kind or "bridge";
        project = fabricDefinition.project or stackDefinition.stackName;
        prefixes = familyAttrs (family: prefixFor family fabricDefinition.subnetId);
        memberRoles = memberRolesFor stackDefinition fabricDefinition;
        reservations = builtins.mapAttrs normalizeReservation (fabricDefinition.reservations or {});
      }
      // (
        if fabricDefinition ? routerHost
        then {routerHost = fabricDefinition.routerHost;}
        else {}
      )
      // (
        if fabricDefinition ? state
        then {state = fabricDefinition.state;}
        else {}
      );
  fabricEntries =
    builtins.concatMap (
      stackName: let
        definition = definitions.${stackName};
        primaryName = primaryFabricName definition;
        networkGroups = builtins.filter (
          group: definition.endpointGroups.${group} ? network
        ) (builtins.attrNames definition.endpointGroups);
      in
        [
          {
            name = primaryName;
            value = normalizeFabric definition definition.network;
          }
        ]
        ++ map (group: {
          name = endpointFabricName definition group;
          value = normalizeFabric definition definition.endpointGroups.${group}.network;
        })
        networkGroups
    )
    definitionNames;
  fabricNames = map (entry: entry.name) fabricEntries;
  fabrics =
    if builtins.length (unique fabricNames) != builtins.length fabricNames
    then throw "Fabric names must be unique: ${builtins.toJSON fabricNames}"
    else builtins.listToAttrs fabricEntries;

  fabricForGroup = definition: group:
    if !builtins.hasAttr group definition.endpointGroups
    then throw "Unknown endpoint group ${definition.stackName}.${group}"
    else endpointFabricName definition group;
  normalizeAccess = definition: id: rawDeclaration: let
    declaration = checkedAttrs "fabric access rule ${id}" ["from" "tcp" "to" "udp"] rawDeclaration;
    source = checkedAttrs "fabric access source ${id}" ["endpointGroups" "role"] (declaration.from or {});
    destination = checkedAttrs "fabric access destination ${id}" ["endpointGroup" "role" "stack"] declaration.to;
    sourceGroups = source.endpointGroups or [definition.activeEndpointGroup];
    destinationDefinition = definitions.${destination.stack};
    destinationGroup = destination.endpointGroup or destinationDefinition.activeEndpointGroup;
  in
    {
      inherit id;
      from =
        {
          fabrics = map (fabricForGroup definition) sourceGroups;
        }
        // (
          if source ? role
          then {role = source.role;}
          else {}
        );
      to =
        {
          fabric = fabricForGroup destinationDefinition destinationGroup;
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
      stackName: let
        definition = definitions.${stackName};
      in
        map (
          id: normalizeAccess definition id definition.access.${id}
        ) (builtins.attrNames (definition.access or {}))
    )
    definitionNames;

  contract =
    if !validAddressBases
    then throw "Fabric address bases must describe valid IPv4 /16 or IPv6 /48 spaces"
    else if !consistentRoleDefinitions
    then throw "Stack definitions in one configuration family must share role host and address definitions"
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
  endpointFor = definition: endpointGroup:
    hydrateEndpoint (
      if endpointGroup == null
      then primaryEndpoint definition
      else endpointDeclaration definition endpointGroup
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

  endpointGroupsFor = definition:
    builtins.mapAttrs (group: _endpoint: let
      hydrated = endpointFor definition group;
    in
      hydrated // {roles = endpointRoleSpecs hydrated;})
    definition.endpointGroups;

  resolveDependencyEndpoint = {
    declaration,
    name,
    definition,
    ...
  }: let
    placement =
      if declaration ? placement
      then {stack = definition.stackName;} // declaration.placement
      else {stack = declaration.stack;};
    placementDefinition = definitions.${placement.stack};
    placementGroup = placement.endpointGroup or declaration.endpointGroup or placementDefinition.activeEndpointGroup;
    base = endpointFor placementDefinition placementGroup;
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
    definition,
    ...
  }: let
    network = endpointFor definition null;
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
      ) (definition.dependencies or {});
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
      stateVolumeSize = definition.stateVolumeSize or null;
    };
  };
}
