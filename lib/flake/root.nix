{
  inputs,
  flake-utils ? inputs.flake-utils,
  nixpkgs ? inputs.nixpkgs,
  systems ? flake-utils.lib.defaultSystems,
  stackProfiles ? import ../stacks,
  servicePlacementFile ? null,
  serviceMoveDirectory ? null,
  phaseProjectionDirectory ? null,
}: let
  flakeProfileInputNames = {
    default = {
      nixpkgs = "nixpkgs";
      homeManager = "home-manager";
      agenix = "agenix";
      disko = "disko";
      vscodeExt = "vscode-ext";
      antigravity = "antigravity";
      p7Borders = "p7-borders";
      p7Cmds = "p7-cmds";
      noctalia = "noctalia";
      llmAgents = "llm-agents";
    };
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

  overlaysFor = profileInputs: import ../../overlays {inputs = profileInputs;};

  mkFlakeProfile = name: inputNames: let
    selected = builtins.mapAttrs (_: inputName: inputs.${inputName}) inputNames;
    profileInputs =
      inputs
      // {
        nixpkgs = selected.nixpkgs;
        home-manager = selected.homeManager;
        agenix = selected.agenix;
        disko = selected.disko;
        vscode-ext = selected.vscodeExt;
        antigravity = selected.antigravity;
        p7-borders = selected.p7Borders;
        p7-cmds = selected.p7Cmds;
        noctalia = selected.noctalia;
        llm-agents = selected.llmAgents;
      };
  in
    selected
    // {
      name = name;
      inputs = profileInputs;
      overlays = overlaysFor profileInputs;
    };

  flakeProfiles = builtins.mapAttrs mkFlakeProfile flakeProfileInputNames;

  overlays = flakeProfiles.default.overlays;

  servicePlacement = import ./service-placements.nix {
    inherit (nixpkgs) lib;
    file = servicePlacementFile;
  };
  canonicalStackProfiles = servicePlacement.applyToStacks stackProfiles;
  legacyPhaseProjection = import ./phase-projection.nix {
    inherit (nixpkgs) lib;
    directory = phaseProjectionDirectory;
  };
  serviceMoves = import ./service-moves.nix {
    inherit (nixpkgs) lib;
    stacks = canonicalStackProfiles;
    inventory = nixbotInventory;
    directory = serviceMoveDirectory;
  };
  servicePlacementAdmission = import ./service-placement-admission.nix {
    inherit (nixpkgs) lib;
    baselineStacks = stackProfiles;
    effectiveStacks = canonicalStackProfiles;
    moveContract = serviceMoves.contract;
  };
  phaseProjection = import ./phase-projection.nix {
    inherit (nixpkgs) lib;
    documents = legacyPhaseProjection.documents ++ serviceMoves.projections;
  };
  effectiveServicePlacements =
    servicePlacement.document
    // {
      controller_reconcile_exclusions = nixpkgs.lib.unique (
        servicePlacement.document.controller_reconcile_exclusions
        ++ serviceMoves.contract.controller_reconcile_exclusions
      );
    };
  effectiveStackProfiles = phaseProjection.applyToStacks canonicalStackProfiles;
  nixbotInventory = import ../../hosts/nixbot.nix;
  nixbotControllerCapability = nixbotInventory.config.controller;
  nixbotInventoryHosts = builtins.attrNames nixbotInventory.hosts;
  nixbotControllerCandidates =
    builtins.filter (
      host:
        (nixbotInventory.hosts.${host}.resourceId or host)
        == nixbotControllerCapability
    )
    nixbotInventoryHosts;
  nixbotControllerHost = assert builtins.length nixbotControllerCandidates == 1;
    builtins.head nixbotControllerCandidates;
  closeoutRuntimeHosts = nixpkgs.lib.unique (
    builtins.concatMap
    (closeout: closeout.affected_hosts)
    (builtins.attrValues servicePlacement.document.closeouts)
  );
  projectionRuntimeHosts =
    builtins.filter (
      host: host != nixbotControllerHost
    )
    (nixpkgs.lib.unique (phaseProjection.runtimeHosts ++ closeoutRuntimeHosts));
  validatedProjectionRuntimeHosts = assert nixpkgs.lib.all (
    host: builtins.elem host nixbotInventoryHosts
  )
  projectionRuntimeHosts; projectionRuntimeHosts;

  rootLib = import ./. {
    inherit flake-utils inputs nixpkgs overlays;
    stackProfiles = effectiveStackProfiles;
  };

  packageOutputs = rootLib.outputsFor systems;

  commonModulesFor = flakeProfile: [
    flakeProfile.homeManager.nixosModules.home-manager
    flakeProfile.agenix.nixosModules.default
    {nixpkgs.overlays = flakeProfile.overlays;}
    ../podman-compose
    ../services/abird-host-agent
    rootLib.serviceModule.portCheckModule
    {imports = builtins.attrValues (builtins.removeAttrs rootLib.nixosModules ["default"]);}
  ];

  defaultStack = {
    nixosConfig = {...}: {
      disabledUsers = {};
      disabledGroups = {};
      disabledActivationScripts = {};
    };
  };

  mkNixosSystem = {
    hostName,
    flakeProfile ? flakeProfiles.default,
    machineProfile ? null,
    modules,
    stack ? null,
    system ? "x86_64-linux",
  }: let
    selectedInputs = flakeProfile.inputs;
    effectiveStack =
      if stack == null
      then defaultStack
      else stack;
    selectedMachineProfileModules =
      if machineProfile == null
      then []
      else [machineProfile.module];
  in
    flakeProfile.nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit flakeProfile flakeProfiles hostName machineProfile machineProfiles system;
        inputs = selectedInputs;
        stack = effectiveStack;
        stacks = effectiveStackProfiles;
        servicePlacements = effectiveServicePlacements;
        serviceMoveContract = serviceMoves.contract;
        inherit servicePlacementAdmission;
        phaseProjections = phaseProjection.documents;
      };
      modules =
        commonModulesFor flakeProfile
        ++ [
          {
            system.configurationRevision = inputs.self.rev or null;
            home-manager.extraSpecialArgs = {
              inherit flakeProfile flakeProfiles machineProfile machineProfiles;
              inputs = selectedInputs;
              stack = effectiveStack;
              stacks = effectiveStackProfiles;
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
        stacks = effectiveStackProfiles;
        servicePlacements = effectiveServicePlacements;
        serviceMoves = serviceMoves.contract;
        inherit servicePlacementAdmission;
      };
      overlays.default = overlay;
    };
in {
  outputs = outputs;
}
