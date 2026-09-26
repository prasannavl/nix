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
  repoChecksFn ? ({...}: {}),
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
  accountsLib = import ./accounts/lib.nix;
  validation = import ../validation;
  inherit (validation.mk "invalid flake root") require;
  inherit (import ./service-stack.nix) isServiceStack;
  canonicalStacks = repositoryConfig.stacks;
  scopeStacks = repositoryConfig.scopeStacks;
  fabrics = repositoryConfig.fabrics;
  nixbotInventory =
    if builtins.isFunction repositoryInventory
    then repositoryInventory {stacks = canonicalStacks;}
    else repositoryInventory;
  inventoryNixCache = nixbotInventory.config.registries.nix or null;
  repositoryNix = {
    substituters = nixpkgs.lib.unique (
      nixpkgs.lib.optional (inventoryNixCache != null) inventoryNixCache.url
      ++ repositoryConfig.nix.substituters
    );
    trustedPublicKeys = repositoryConfig.nix.trustedPublicKeys;
  };
  machineProfiles = {
    vm = {
      name = "vm";
      module = ../profiles/vm.nix;
    };
    incusLxc = {
      name = "incus-lxc";
      module = ../profiles/incus-lxc.nix;
    };
    incusVm = {
      name = "incus-vm";
      module = ../profiles/incus-vm.nix;
    };
  };

  overlaysFor = inputSetInputs: import ../../overlays {inputs = inputSetInputs;};

  mkInputSet = name: inputNames: let
    selected = builtins.mapAttrs (_: inputName: inputs.${inputName}) inputNames;
    # Each input-set key selects a flake input; the selected values override the
    # same-named flake inputs so hosts see e.g. inputSet.inputs.home-manager.
    inputSetInputs =
      inputs
      // nixpkgs.lib.mapAttrs'
      (profileKey: inputName: nixpkgs.lib.nameValuePair inputName selected.${profileKey})
      inputNames;
  in
    selected
    // {
      name = name;
      inputs = inputSetInputs;
      overlays = overlaysFor inputSetInputs;
    };

  inputSets = builtins.mapAttrs mkInputSet inputSetInputNames;

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
  runtimeProjectionCloseouts = import ./runtime-projection-closeouts.nix {
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
  nixbotControllerCandidates =
    builtins.filter (
      host:
        (nixbotInventory.hosts.${host}.resourceId or host)
        == nixbotControllerCapability
    )
    nixbotInventoryHosts;
  nixbotControllerHost = assert require (builtins.length nixbotControllerCandidates == 1) "inventory controller capability ${nixbotControllerCapability} must select exactly one host";
    builtins.head nixbotControllerCandidates;
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
    inherit flake-utils inputs nixpkgs overlays repoChecksFn repositoryConfig;
    stacks = effectiveStacks;
  };

  packageOutputs = rootLib.outputsFor systems;

  repoModuleComposition = import ./repo-modules.nix {
    inherit (nixpkgs) lib;
    repoModules = repositoryConfig.modules;
    stacks = effectiveStacks;
  };

  commonModulesFor = inputSet: selectedRepoModules:
    [
      inputSet.homeManager.nixosModules.home-manager
      inputSet.agenix.nixosModules.default
      {nixpkgs.overlays = inputSet.overlays;}
      ../podman-compose
    ]
    ++ selectedRepoModules
    ++ [
      rootLib.serviceModule.portCheckModule
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
    selectedAccounts =
      if effectiveStack == null
      then repositoryConfig.shared.accounts or null
      else effectiveStack.accounts or null;
    accounts =
      if accountsLib.isAccounts selectedAccounts
      then selectedAccounts
      else if effectiveStack == null
      then throw "stack-independent system ${hostName} requires a valid repository.shared.accounts contract"
      else throw "stack ${effectiveStack.stackName or hostName} requires a valid accounts contract";
    repository = {
      inherit fabrics;
      inventory = nixbotInventory;
      nix = repositoryNix;
      inherit (repositoryConfig) shared;
      stacks = effectiveStacks;
    };
  in
    inputSet.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit accounts hostName inputSet inputSets machineProfile machineProfiles repository system;
        inputs = selectedInputs;
        inherit repoModulePkgs;
        stack = effectiveStack;
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

  nixosConfigurations = import ../../hosts {
    inherit machineProfiles mkNixosSystem;
    stacks = rootLib.stacks;
  };

  nixosImages = import ../images {
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
