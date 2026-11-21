{
  inputs,
  flake-utils ? inputs.flake-utils,
  nixpkgs ? inputs.nixpkgs,
  systems ? flake-utils.lib.defaultSystems,
  # Repository composition enters exclusively through these injected
  # arguments; the shared assembly below names no repository path or stack set.
  # The manifest (flake.nix) supplies them (see
  # .agents/docs/design-patterns/shared-test-areas.md).
  repositoryConfig,
  repositoryInventory,
  # Runtime-only host/instance/resource projections: null when unsupported.
  phaseProjectionDirectory ? null,
  # Runtime-only closeout and local-controller evidence, separate from stable
  # service placement authority.
  runtimeProjectionCloseoutsFile ? null,
  # Shared host-agent service option; overridable when a repository ships the
  # host agent under another name.
  hostAgentServiceName ? "abird-host-agent",
  repositoryChecksFor ? null,
  externalPackagesFor ? _system: {},
  inputSetInputNames ? {
    default = {
      nixpkgs = "nixpkgs";
      homeManager = "home-manager";
      agenix = "agenix";
      disko = "disko";
      vscodeExt = "vscode-ext";
    };
  },
  defaultMachineProfileName ? null,
}: let
  ab = import ../ab;
  accountsLib = ab.stack.accounts;
  validation = ab.core.validation;
  inherit (validation.mk "invalid flake root") require;
  inherit (ab.stack.serviceStack) isServiceStack;
  canonicalStacks = repositoryConfig.stacks;
  scopeStacks = repositoryConfig.scopeStacks;
  fabrics = repositoryConfig.fabrics;
  nixbotInventory =
    if builtins.isFunction repositoryInventory
    then repositoryInventory {stacks = canonicalStacks;}
    else repositoryInventory;
  inventoryNixCache = nixbotInventory.config.registries.nix or null;
  repositoryNix = {
    caches = repositoryConfig.nix.caches;
    substituters = nixpkgs.lib.unique (
      nixpkgs.lib.optional (inventoryNixCache != null && !(builtins.elem inventoryNixCache.url (map (cache: cache.url) (builtins.attrValues repositoryConfig.nix.caches)))) inventoryNixCache.url
      ++ repositoryConfig.nix.substituters
    );
    trustedPublicKeys = repositoryConfig.nix.trustedPublicKeys;
  };
  machineProfiles = {
    vm = {
      name = "vm";
      module = ./profiles/vm.nix;
    };
    incusLxc = {
      name = "incus-lxc";
      module = ./profiles/incus-lxc.nix;
    };
    incusVm = {
      name = "incus-vm";
      module = ./profiles/incus-vm.nix;
    };
  };

  overlaysFor = inputSetInputs: import ./overlays {inputs = inputSetInputs;};

  inputSets = ab.repo.inputSets {inherit (nixpkgs) lib;} {
    inherit inputs overlaysFor;
    definitions = inputSetInputNames;
  };

  overlays = inputSets.default.overlays;

  inventoryEndpointForHost = declaredHost: let
    exact =
      if builtins.hasAttr declaredHost nixbotInventory.hosts
      then [declaredHost]
      else [];
    resourceMatches = builtins.filter (
      host: (nixbotInventory.hosts.${host}.resourceId or host) == declaredHost
    ) (builtins.attrNames nixbotInventory.hosts);
    matches =
      if exact != []
      then exact
      else resourceMatches;
  in
    assert require (builtins.length matches <= 1) "inventory host ${declaredHost} matches more than one resource identity";
      if matches == []
      then null
      else let
        host = builtins.head matches;
        inventoryHost = nixbotInventory.hosts.${host};
      in {
        inherit host;
        host_resource = "host:${inventoryHost.resourceId or host}";
      };
  projectionDomains = import ./projection-domains.nix {
    inherit (nixpkgs) lib;
    stacks = scopeStacks;
    inventory = nixbotInventory;
    scopeOwners = repositoryConfig.scopeOwners;
    scopeDefinitions = repositoryConfig.scopeDefinitions;
    repositoryProjections = repositoryConfig.projections;
    phaseProjectionDirectory = phaseProjectionDirectory;
    extraAdapters = repositoryConfig.projectionAdapters;
    extraRuntimeAdapters = repositoryConfig.projectionRuntimeAdapters;
  };
  phaseProjection = projectionDomains.phaseProjection;
  serviceMoveContract = projectionDomains.contracts.serviceMoves;
  servicePlacementDocument = projectionDomains.contracts.servicePlacements;
  runtimeProjectionCloseouts = ab.repo.runtimeCloseouts {
    inherit (nixpkgs) lib;
    document =
      if runtimeProjectionCloseoutsFile != null && builtins.pathExists runtimeProjectionCloseoutsFile
      then builtins.fromJSON (builtins.readFile runtimeProjectionCloseoutsFile)
      else null;
  };
  effectiveScopeStacks = projectionDomains.effectiveStacks;
  effectiveStacks = repositoryConfig.materializeScopeStacks effectiveScopeStacks;
  nixbotControllerCapability = nixbotInventory.config.controller;
  nixbotInventoryHosts = builtins.attrNames nixbotInventory.hosts;
  nixbotControllerEndpoint = inventoryEndpointForHost nixbotControllerCapability;
  nixbotControllerHost = assert require (nixbotControllerEndpoint != null) "inventory controller capability ${nixbotControllerCapability} must select one host";
    nixbotControllerEndpoint.host;
  closeoutRuntimeHosts = nixpkgs.lib.unique (
    builtins.concatMap
    (closeout: closeout.affected_hosts)
    (builtins.attrValues runtimeProjectionCloseouts.closeouts)
  );
  projectionRuntimeHosts =
    builtins.filter (
      host: host != nixbotControllerHost
    )
    (nixpkgs.lib.unique (projectionDomains.runtime.runtimeHosts ++ closeoutRuntimeHosts));
  validatedProjectionRuntimeHosts = assert require (nixpkgs.lib.all (
      host: builtins.elem host nixbotInventoryHosts
    )
    projectionRuntimeHosts) "projection runtime hosts must all exist in the deployment inventory"; projectionRuntimeHosts;

  rootLib = import ./. {
    inherit externalPackagesFor flake-utils inputs nixpkgs overlays repositoryChecksFor repositoryConfig;
    stacks = effectiveStacks;
  };

  packageOutputs = rootLib.outputsFor systems;

  repoModuleComposition = ab.repo.modules {
    inherit (nixpkgs) lib;
    repoModules = repositoryConfig.modules;
    stacks = effectiveStacks;
  };

  commonModulesFor = inputSet: selectedRepoModules:
    [
      inputSet.homeManager.nixosModules.home-manager
      inputSet.agenix.nixosModules.default
      {nixpkgs.overlays = inputSet.overlays;}
      ./podman.nix
    ]
    ++ selectedRepoModules
    ++ [
      ab.services.modules.abirdHostAgentNixosAdapter
      {imports = builtins.attrValues (builtins.removeAttrs rootLib.nixosModules ["default"]);}
    ];

  mkNixosSystem = {
    hostName,
    inputSet ? inputSets.default,
    machineProfile ? (
      if defaultMachineProfileName == null
      then null
      else machineProfiles.${defaultMachineProfileName}
    ),
    modules,
    stack ? null,
    system ? "x86_64-linux",
  }: let
    selectedInputs = inputSet.inputs;
    effectiveStack = stack;
    selectedMachineProfileModules =
      if machineProfile == null
      then []
      else [machineProfile.module];
    selectedRepoModules = repoModuleComposition.modulesFor stack;
    repoModulePkgs = import inputSet.nixpkgs {
      inherit system;
      overlays = inputSet.overlays;
    };
    # Package/module constructors keep the narrower package-author context.
    repoModuleAb = ab.core.mk {
      pkgs = repoModulePkgs;
      projectRoot = ../.;
      treefmtConfig = ../treefmt.toml;
    };
    selectedAccounts =
      if effectiveStack == null
      then repositoryConfig.shared.accounts or null
      else effectiveStack.accounts or null;
    accounts =
      if accountsLib.isAccounts selectedAccounts
      then selectedAccounts
      else if effectiveStack == null
      then throw "stack-independent system ${hostName} requires a valid repository.shared.accounts contract"
      else throw "stack ${effectiveStack.name or hostName} requires a valid accounts contract";
    repository = {
      inherit fabrics;
      inventory = nixbotInventory;
      nix = ab.repo.cache.forHost {
        policy = repositoryNix;
        host = hostName;
        fabric = effectiveStack.network.fabric or null;
      };
      inherit (repositoryConfig) shared;
      stacks = effectiveStacks;
    };
  in
    inputSet.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        ab = ab.forPkgs {
          pkgs = repoModulePkgs;
          projectRoot = ../.;
          treefmtConfig = ../treefmt.toml;
        };
        inherit accounts hostName inputSet inputSets machineProfile machineProfiles repository system;
        inputs = selectedInputs;
        inherit repoModuleAb repoModulePkgs;
        stack = effectiveStack;
        abNixosPkgs = repoModulePkgs;
        abNixosUser =
          if effectiveStack == null
          then null
          else effectiveStack.service.user;
        abNixosPolicy =
          if effectiveStack == null
          then null
          else {
            identityFor = serviceName:
              effectiveStack.identity.mk {
                name = serviceName;
                suffix = effectiveStack.identity.serviceSuffix;
              };
            nats = effectiveStack.nats;
            postgres = effectiveStack.postgres;
          };
        serviceMoveContract = serviceMoveContract;
        inherit runtimeProjectionCloseouts;
        projectionAdmission = projectionDomains.admission;
        phaseProjections = phaseProjection.documents;
      };
      modules =
        commonModulesFor inputSet selectedRepoModules
        ++ [
          {
            system.configurationRevision = inputs.self.rev or null;
            home-manager.extraSpecialArgs = {
              inherit accounts inputSet inputSets machineProfile machineProfiles repository;
              inputs = selectedInputs;
              stack = effectiveStack;
            };
          }
        ]
        ++ selectedMachineProfileModules
        ++ modules;
    };

  devShellsLib = import ./dev-shells.nix {
    inherit (nixpkgs) lib;
  };

  devShells = nixpkgs.lib.genAttrs systems (system: let
    pkgs = import nixpkgs {
      inherit system overlays;
    };
  in
    devShellsLib.mkDevShells {
      inherit pkgs;
      rootPackages = [
        pkgs.alejandra
        pkgs.git
        pkgs.jq
        pkgs.nix
        pkgs.nix-output-monitor
        pkgs.nvd
        inputs.agenix.packages.${system}.default
      ];
      childPackages = packageOutputs.${system}.packages;
    });

  overlay = nixpkgs.lib.composeManyExtensions overlays;
  pkgs = nixpkgs.lib.mapAttrs (_: outputs: outputs.packages) packageOutputs;
  standardOutputs = rootLib.standardOutputsFrom systems packageOutputs;

  nixosConfigurations = import ../hosts {
    inherit machineProfiles mkNixosSystem;
    stacks = rootLib.stacks;
  };

  nixosImages = import ./images.nix {
    inherit machineProfiles mkNixosSystem;
    stacks = rootLib.stacks;
  };

  # We use this for build plan cache.
  # It's entirely optional and non necessary.
  nixbot = {
    deployDependencies = {
      ${nixbotControllerHost} = validatedProjectionRuntimeHosts;
    };
    plans =
      nixpkgs.lib.mapAttrs (_: nixosConfig: {
        drvPath = nixosConfig.config.system.build.toplevel.drvPath;
      })
      nixosConfigurations;
  };

  outputs =
    standardOutputs
    // {
      inherit devShells nixbot nixosConfigurations nixosImages pkgs;
      inherit (rootLib) nixosModules;
      hostManager = {
        inherit (repositoryConfig) defaultSelection;
        stacks = effectiveStacks;
        scopes = effectiveScopeStacks;
        servicePlacements = servicePlacementDocument;
        inherit runtimeProjectionCloseouts;
        serviceResourcesByHost =
          nixpkgs.lib.mapAttrs
          (_host: nixosConfig: nixosConfig.config.services.${hostAgentServiceName}.services)
          nixosConfigurations;
        scopeCatalog = projectionDomains.scopeCatalog;
        serviceMoveRepositoryMutationsFor = projectionDomains.serviceMoveMutationsFor;
        projectionDomains = {
          schema_version = projectionDomains.schema_version;
          inherit (projectionDomains) claims contracts repository runtime;
          generation = projectionDomains.generation.domains;
          admission = projectionDomains.admission;
        };
        projectionSnapshot = {
          schema_version = 1;
          repository = projectionDomains.repository;
          service_moves = serviceMoveContract;
          service_placements = servicePlacementDocument;
          runtime_plans = projectionDomains.runtime.plans;
          scope_role_endpoints = nixpkgs.lib.mapAttrs (_scope: stack:
            nixpkgs.lib.filterAttrs (_role: endpoint: endpoint != null)
            (nixpkgs.lib.mapAttrs (_role: role: inventoryEndpointForHost role.host) stack.serviceRegistry.roles))
          (nixpkgs.lib.filterAttrs (_scope: isServiceStack) effectiveScopeStacks);
        };
      };
      overlays.default = overlay;
    };
in {
  outputs = outputs;
}
