{
  inputs,
  flake-utils ? inputs.flake-utils,
  nixpkgs ? inputs.nixpkgs,
  systems ? flake-utils.lib.defaultSystems,
  stackProfiles ? import ../stacks,
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

  rootLib = import ./. {
    inherit flake-utils inputs nixpkgs overlays stackProfiles;
  };

  packageOutputs = rootLib.outputsFor systems;

  commonModulesFor = flakeProfile: [
    flakeProfile.homeManager.nixosModules.home-manager
    flakeProfile.agenix.nixosModules.default
    {nixpkgs.overlays = flakeProfile.overlays;}
    ../podman-compose
    ../systemd-user-manager
    ../../pkgs/tools/nixbot/nixos-module.nix
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
        stacks = stackProfiles;
      };
      modules =
        commonModulesFor flakeProfile
        ++ [
          {
            home-manager.extraSpecialArgs = {
              inherit flakeProfile flakeProfiles machineProfile machineProfiles;
              inputs = selectedInputs;
              stack = effectiveStack;
              stacks = stackProfiles;
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
      overlays.default = overlay;
    };
in {
  outputs = outputs;
}
