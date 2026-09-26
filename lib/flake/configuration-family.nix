{
  defaults,
  placementScopes ? {},
  stackDefinitions,
  registryFor,
}: let
  validation = import ../validation;
  inherit (validation) isName isNonEmptyString;
  inherit (validation.mk "invalid configuration family") require requireOnly uniqueStrings;
  defaultsFields = [
    "certificates"
    "extIdentitySuffix"
    "fabric"
    "identitySuffix"
    "nats"
    "org"
    "postgres"
    "secretGroup"
    "secretOwner"
    "secrets"
    "serviceIdentitySuffix"
    "splitHorizonRole"
    "trustedCidrs"
    "user"
  ];
  stackDefinitionFields = [
    "access"
    "activeEndpointGroup"
    "dependencies"
    "dnsRouteDomains"
    "domain"
    "domainNames"
    "enableExternalConnectors"
    "endpointGroups"
    "env"
    "extraTunnelDomainNames"
    "instances"
    "internalDomain"
    "network"
    "secretScope"
    "stateVolumeSize"
    "tunnelDomainNames"
    "tunnels"
  ];
  networkFields = ["kind" "members" "name" "nodeLabel" "priority" "project" "reservations" "routerHost" "state" "subnetId"];
  endpointGroupFields =
    networkFields
    ++ [
      "activeEndpointGroup"
      "enableExternalConnectors"
      "network"
      "roles"
      "tunnels"
      "weight"
    ];
  optional = attrs: field: predicate:
    !(builtins.hasAttr field attrs) || predicate attrs.${field};
  pathLike = value:
    builtins.isPath value || isNonEmptyString value;
  stringList = context: values:
    builtins.deepSeq (uniqueStrings context values) true;
  validateNetwork = context: network:
    require (builtins.isAttrs network) "${context} must be an attribute set"
    && requireOnly networkFields network context
    && require (optional network "kind" isNonEmptyString) "${context} kind must be a non-empty string"
    && require (optional network "members" builtins.isAttrs) "${context} members must be an attribute set"
    && require (optional network "name" isNonEmptyString) "${context} name must be a non-empty string"
    && require (optional network "nodeLabel" isNonEmptyString) "${context} nodeLabel must be a non-empty string"
    && require (optional network "priority" builtins.isInt) "${context} priority must be an integer"
    && require (optional network "project" isNonEmptyString) "${context} project must be a non-empty string"
    && require (optional network "reservations" builtins.isAttrs) "${context} reservations must be an attribute set"
    && require (optional network "routerHost" isNonEmptyString) "${context} routerHost must be a non-empty string"
    && require (optional network "state" isNonEmptyString) "${context} state must be a non-empty string"
    && require (optional network "subnetId" builtins.isInt) "${context} subnetId must be an integer";
  validateEndpointGroup = stackName: group: declaration: let
    context = "stack definition ${stackName} endpoint group ${group}";
  in
    require (builtins.isAttrs declaration) "${context} must be an attribute set"
    && requireOnly endpointGroupFields declaration context
    && validateNetwork context (builtins.removeAttrs declaration ["activeEndpointGroup" "enableExternalConnectors" "network" "roles" "tunnels" "weight"])
    && require (optional declaration "activeEndpointGroup" isNonEmptyString) "${context} activeEndpointGroup must be a non-empty string"
    && require (optional declaration "enableExternalConnectors" builtins.isBool) "${context} enableExternalConnectors must be a boolean"
    && require (optional declaration "network" (network: validateNetwork "${context} network" network)) "${context} network is invalid"
    && require (optional declaration "roles" builtins.isAttrs) "${context} roles must be an attribute set"
    && require (optional declaration "tunnels" builtins.isAttrs) "${context} tunnels must be an attribute set"
    && require (optional declaration "weight" builtins.isInt) "${context} weight must be an integer";
  validatedDefaults = assert require (builtins.isAttrs defaults) "defaults must be an attribute set";
  assert requireOnly defaultsFields defaults "defaults";
  assert require (isName (defaults.org or null)) "defaults org must be a safe name";
  assert require (isNonEmptyString (defaults.identitySuffix or null)) "defaults identitySuffix must be a non-empty string";
  assert require (builtins.isAttrs (defaults.fabric or null)) "defaults fabric must be an attribute set";
  assert requireOnly ["addressBases" "preferredServiceFamily"] defaults.fabric "defaults fabric";
  assert require (builtins.isAttrs (defaults.fabric.addressBases or null)) "defaults fabric addressBases must be an attribute set";
  assert require (optional defaults.fabric "preferredServiceFamily" isNonEmptyString) "defaults fabric preferredServiceFamily must be a non-empty string";
  assert require (optional defaults "trustedCidrs" (stringList "defaults trustedCidrs")) "defaults trustedCidrs are invalid";
  assert require (optional defaults "splitHorizonRole" isNonEmptyString) "defaults splitHorizonRole must be a non-empty string";
  assert require (optional defaults "user" isNonEmptyString) "defaults user must be a non-empty string";
  assert require (optional defaults "extIdentitySuffix" isNonEmptyString) "defaults extIdentitySuffix must be a non-empty string";
  assert require (optional defaults "serviceIdentitySuffix" isNonEmptyString) "defaults serviceIdentitySuffix must be a non-empty string";
  assert require (optional defaults "secretOwner" isNonEmptyString) "defaults secretOwner must be a non-empty string";
  assert require (optional defaults "secretGroup" isNonEmptyString) "defaults secretGroup must be a non-empty string"; defaults;
  secrets = validatedDefaults.secrets or {};
  certificates = validatedDefaults.certificates or {};
  postgres = validatedDefaults.postgres or {};
  nats = validatedDefaults.nats or {};
  validateStackDefinition = name: definition:
    assert require (builtins.isAttrs definition) "stack definition ${name} must be an attribute set";
    assert require (!(definition ? secretNamespace)) "stack definition ${name} may not override secretNamespace; use secretScope for stack-specific secret paths";
    assert requireOnly stackDefinitionFields definition "stack definition ${name}"; let
      normalizedDefinition = definition // {stackName = name;};
      network = normalizedDefinition.network or {};
      endpointGroups = normalizedDefinition.endpointGroups or {};
      instances = normalizedDefinition.instances or {};
      dependencies = normalizedDefinition.dependencies or {};
      registry = registryFor normalizedDefinition;
      roleOverlap = builtins.filter (role: builtins.hasAttr role dependencies) (builtins.attrNames instances);
      validateRole = kind: controls: role: declaration: let
        registryRole = registry.roles.${role} or null;
        allowed =
          controls
          ++ (
            if registryRole == null
            then []
            else builtins.attrNames registryRole
          );
      in
        require (builtins.isAttrs declaration) "stack definition ${name} ${kind} role ${role} must be an attribute set"
        && require (registryRole != null) "stack definition ${name} ${kind} role ${role} is not declared by its registry"
        && requireOnly allowed declaration "stack definition ${name} ${kind} role ${role}";
    in
      assert require (isNonEmptyString (normalizedDefinition.env or null)) "stack definition ${name} env must be a non-empty string";
      assert require (isNonEmptyString (normalizedDefinition.domain or null)) "stack definition ${name} domain must be a non-empty string";
      assert require (isNonEmptyString (normalizedDefinition.internalDomain or null)) "stack definition ${name} internalDomain must be a non-empty string";
      assert require (isNonEmptyString (normalizedDefinition.activeEndpointGroup or null)) "stack definition ${name} activeEndpointGroup must be a non-empty string";
      assert require (builtins.isBool (normalizedDefinition.enableExternalConnectors or null)) "stack definition ${name} enableExternalConnectors must be a boolean";
      assert require (validateNetwork "stack definition ${name} network" network) "stack definition ${name} network is invalid";
      assert require (builtins.isAttrs endpointGroups && endpointGroups != {}) "stack definition ${name} endpointGroups must be a non-empty attribute set";
      assert require (builtins.all (group: validateEndpointGroup name group endpointGroups.${group}) (builtins.attrNames endpointGroups)) "stack definition ${name} has an invalid endpoint group";
      assert require (builtins.hasAttr (normalizedDefinition.activeEndpointGroup or "") endpointGroups) "stack definition ${name} activeEndpointGroup is not declared";
      assert require (builtins.isAttrs instances && builtins.isAttrs dependencies) "stack definition ${name} instances and dependencies must be attribute sets";
      assert require (builtins.isAttrs (normalizedDefinition.tunnels or {})) "stack definition ${name} tunnels must be an attribute set";
      assert require (builtins.isAttrs (normalizedDefinition.access or {})) "stack definition ${name} access must be an attribute set";
      assert require (builtins.all builtins.isAttrs (builtins.attrValues (normalizedDefinition.access or {}))) "stack definition ${name} access rules must be attribute sets";
      assert require (optional normalizedDefinition "dnsRouteDomains" (stringList "stack definition ${name} dnsRouteDomains")) "stack definition ${name} dnsRouteDomains are invalid";
      assert require (optional normalizedDefinition "domainNames" (stringList "stack definition ${name} domainNames")) "stack definition ${name} domainNames are invalid";
      assert require (optional normalizedDefinition "tunnelDomainNames" (stringList "stack definition ${name} tunnelDomainNames")) "stack definition ${name} tunnelDomainNames are invalid";
      assert require (optional normalizedDefinition "extraTunnelDomainNames" (stringList "stack definition ${name} extraTunnelDomainNames")) "stack definition ${name} extraTunnelDomainNames are invalid";
      assert require (optional normalizedDefinition "stateVolumeSize" isNonEmptyString) "stack definition ${name} stateVolumeSize must be a non-empty string";
      assert require (optional normalizedDefinition "secretScope" isName) "stack definition ${name} secretScope must be a safe name";
      assert require (builtins.all (domain: builtins.hasAttr domain registry.domains) (normalizedDefinition.domainNames or [])) "stack definition ${name} domainNames reference unknown registry domains";
      assert require (builtins.all (domain: builtins.hasAttr domain registry.domains) (normalizedDefinition.tunnelDomainNames or [])) "stack definition ${name} tunnelDomainNames reference unknown registry domains";
      assert require (builtins.all (domain: builtins.hasAttr domain registry.domains) (normalizedDefinition.extraTunnelDomainNames or [])) "stack definition ${name} extraTunnelDomainNames reference unknown registry domains";
      assert require (builtins.all (role: validateRole "owned" ["endpoint"] role instances.${role}) (builtins.attrNames instances)) "stack definition ${name} has an invalid owned role";
      assert require (builtins.all (role: validateRole "dependency" ["endpoint" "endpointGroup" "placement" "stack"] role dependencies.${role}) (builtins.attrNames dependencies)) "stack definition ${name} has an invalid dependency role";
      assert require (roleOverlap == []) "stack definition ${name} roles may not be both owned and dependencies: ${builtins.concatStringsSep ", " roleOverlap}"; normalizedDefinition;
  validatedStackDefinitions = builtins.mapAttrs validateStackDefinition stackDefinitions;
  org = validatedDefaults.org;
  secretNamespace = secrets.namespace or org;
  secretDirectory = secrets.directory or null;
  secretLabelRoot = secrets.labelRoot or null;
  fabricStack = import ./fabric-stack.nix {
    definitions = validatedStackDefinitions;
    inherit registryFor;
    addressBases = validatedDefaults.fabric.addressBases;
    preferredServiceFamily = validatedDefaults.fabric.preferredServiceFamily or "ipv4";
  };
  fabric = fabricStack.contract;
  trustedCidrs = builtins.concatLists (builtins.attrValues fabric.internalPrefixes) ++ (validatedDefaults.trustedCidrs or []);
  splitHorizonRole = validatedDefaults.splitHorizonRole or "proxy";
  secretRoot = secretDirectory + "/${secretNamespace}";
  secretLabel = "${secretLabelRoot}/${secretNamespace}";
  user = validatedDefaults.user or org;
  identitySuffix = validatedDefaults.identitySuffix;
  stackBaseArgs =
    {
      defaultUser = user;
      stackSecretsBasePath = secretRoot;
      stackSecretsLabel = secretLabel;
      defaultClientSecretsBasePath = secretRoot + "/services";
      defaultNatsSecretsBasePath = secretRoot + "/nats";
      defaultPostgresSecretsBasePath = secretRoot + "/postgres";
      defaultVmstackSecretsBasePath = secretRoot + "/vmstack";
      defaultNginxSecretsBasePath = secretRoot + "/nginx";
      defaultClientIdentitySuffix = identitySuffix;
      defaultExtServiceIdentitySuffix = validatedDefaults.extIdentitySuffix or identitySuffix;
      defaultServiceIdentitySuffix = validatedDefaults.serviceIdentitySuffix or identitySuffix;
      defaultSecretOwner = validatedDefaults.secretOwner or user;
      defaultSecretGroup = validatedDefaults.secretGroup or user;
      defaultPostgresUrl = postgres.url or "";
      defaultPostgresAfter = postgres.after or [];
      defaultNatsUrl = nats.url or "";
      defaultNatsAfter = nats.after or [];
    }
    // (
      if certificates ? root
      then {defaultCaCertBasePath = certificates.root;}
      else {}
    )
    // (
      if certificates ? hostPath
      then {defaultCaCertHostPath = certificates.hostPath;}
      else {}
    )
    // (
      if certificates ? containerPath
      then {defaultCaCertContainerPath = certificates.containerPath;}
      else {}
    )
    // (
      if postgres ? caCertPath
      then {defaultPostgresCaCertPath = postgres.caCertPath;}
      else {}
    )
    // (
      if nats ? caCertPath
      then {defaultNatsCaCertPath = nats.caCertPath;}
      else {}
    );

  mkRegistryArgs = {
    constructor,
    domains,
    definition,
    registry,
    roles,
    services,
    tunnelDomains,
  }: {
    inherit
      constructor
      domains
      org
      roles
      services
      splitHorizonRole
      stackBaseArgs
      trustedCidrs
      tunnelDomains
      ;
    inherit
      (definition)
      activeEndpointGroup
      domain
      enableExternalConnectors
      env
      internalDomain
      stackName
      tunnels
      ;
    endpointGroups = fabricStack.endpointGroupsFor definition;
    dnsRouteDomains = definition.dnsRouteDomains or ["~${definition.internalDomain}" "~${definition.domain}"];
    limits = registry.limits;
    secretNamespace = secretNamespace;
    secretScope = definition.secretScope or null;
  };

  stacks = import ./stack/build-set.nix {
    inherit mkRegistryArgs registryFor;
    inherit (fabricStack) mkProjection resolveDependencyEndpoint;
    definitions = validatedStackDefinitions;
  };
  validatePlacementScope = name: declaration: let
    source = declaration.stack or null;
    placement = declaration.placement or null;
  in
    assert require (isName name) "placement scope ${name} must have a safe name";
    assert require (builtins.isAttrs declaration) "placement scope ${name} must be an attribute set";
    assert requireOnly ["placement" "stack"] declaration "placement scope ${name}";
    assert require (isNonEmptyString source && builtins.hasAttr source stacks) "placement scope ${name} references an unknown stack";
    assert require (isNonEmptyString placement && builtins.hasAttr placement (stacks.${source}.placements or {})) "placement scope ${name} references an unknown placement"; {
      stack = source;
      inherit placement;
    };
  validatedPlacementScopes = assert require (builtins.isAttrs placementScopes) "placementScopes must be an attribute set";
    builtins.mapAttrs validatePlacementScope placementScopes;
  result = {
    inherit fabric stacks;
    projectionScopes = validatedPlacementScopes;
    projections = {};
  };
in
  assert require (builtins.isAttrs secrets) "configuration family secrets must be an attribute set";
  assert requireOnly ["directory" "labelRoot" "namespace"] secrets "configuration family secrets";
  assert require (builtins.isString secretNamespace && builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" secretNamespace != null) "configuration family secret namespace must be a safe path component";
  assert require (
    builtins.isPath secretDirectory
    || (builtins.isString secretDirectory && secretDirectory != "" && builtins.match ".*/" secretDirectory == null)
  ) "configuration family secret directory must be a path or non-empty string without a trailing slash";
  assert require (builtins.isString secretLabelRoot && secretLabelRoot != "" && builtins.match ".*/" secretLabelRoot == null) "configuration family secret label root must be a non-empty path without a trailing slash";
  assert require (builtins.isAttrs certificates) "defaults certificates must be an attribute set";
  assert requireOnly ["containerPath" "hostPath" "root"] certificates "defaults certificates";
  assert require (optional certificates "root" pathLike) "defaults certificates root must be a path or non-empty string";
  assert require (optional certificates "hostPath" isNonEmptyString) "defaults certificates hostPath must be a non-empty string";
  assert require (optional certificates "containerPath" isNonEmptyString) "defaults certificates containerPath must be a non-empty string";
  assert require (builtins.isAttrs postgres) "defaults postgres must be an attribute set";
  assert requireOnly ["after" "caCertPath" "url"] postgres "defaults postgres";
  assert require (optional postgres "url" isNonEmptyString) "defaults postgres url must be a non-empty string";
  assert require (optional postgres "after" (stringList "defaults postgres after")) "defaults postgres after is invalid";
  assert require (optional postgres "caCertPath" pathLike) "defaults postgres caCertPath must be a path or non-empty string";
  assert require (builtins.isAttrs nats) "defaults nats must be an attribute set";
  assert requireOnly ["after" "caCertPath" "url"] nats "defaults nats";
  assert require (optional nats "url" isNonEmptyString) "defaults nats url must be a non-empty string";
  assert require (optional nats "after" (stringList "defaults nats after")) "defaults nats after is invalid";
  assert require (optional nats "caCertPath" pathLike) "defaults nats caCertPath must be a path or non-empty string";
    builtins.deepSeq {
      inherit validatedDefaults validatedPlacementScopes validatedStackDefinitions;
    }
    result
