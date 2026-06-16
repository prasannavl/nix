{
  inputs,
  flake-utils ? inputs.flake-utils,
  nixpkgs ? inputs.nixpkgs,
  systems ? flake-utils.lib.defaultSystems,
  stackProfiles ? import ../stacks,
}: let
  profileInputNames = {
    stable = {
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

  overlaysFor = profileInputs: import ../../overlays {inputs = profileInputs;};

  mkInputProfile = name: inputNames: let
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

  inputProfiles = builtins.mapAttrs mkInputProfile profileInputNames;
  overlays = inputProfiles.stable.overlays;

  rootLib = import ./. {
    inherit flake-utils inputs nixpkgs overlays stackProfiles;
  };

  packageOutputs = rootLib.outputsFor systems;

  commonModulesFor = inputProfile: [
    inputProfile.homeManager.nixosModules.home-manager
    inputProfile.agenix.nixosModules.default
    {nixpkgs.overlays = inputProfile.overlays;}
    ../podman-compose
    ../services/migrator
    ../systemd-user-manager
    ../../pkgs/tools/nixbot/nixos-module.nix
    rootLib.serviceModule.portCheckModule
    ({lib, ...}: {
      services.migration-manager.enable = lib.mkDefault true;
    })
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
    inputProfile ? inputProfiles.stable,
    modules,
    stack ? null,
    system ? "x86_64-linux",
  }: let
    selectedInputs = inputProfile.inputs;
    effectiveStack =
      if stack == null
      then defaultStack
      else stack;
  in
    inputProfile.nixpkgs.lib.nixosSystem {
      system = system;
      specialArgs = {
        inherit hostName inputProfile inputProfiles system;
        inputs = selectedInputs;
        stack = effectiveStack;
        stacks = stackProfiles;
      };
      modules =
        commonModulesFor inputProfile
        ++ [
          {
            home-manager.extraSpecialArgs = {
              inherit inputProfile inputProfiles;
              inputs = selectedInputs;
              stack = effectiveStack;
              stacks = stackProfiles;
            };
          }
        ]
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
      pkgs = pkgs;
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
    inherit inputProfiles mkNixosSystem;
    stacks = rootLib.stacks;
  };

  nixosImages = import ../images {
    mkNixosSystem = mkNixosSystem;
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
