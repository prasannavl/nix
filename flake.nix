{
  description = "NixOS Config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
        systems.follows = "systems";
      };
    };
    nixos-hardware.url = "github:nixos/nixos-hardware";
    vscode-ext = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        systems.follows = "systems";
        treefmt-nix.follows = "treefmt-nix";
      };
    };
    antigravity = {
      url = "github:jacopone/antigravity-nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    p7-borders = {
      url = "github:prasannavl/p7-borders-shell-extension";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    p7-cmds = {
      url = "github:prasannavl/p7-cmds-shell-extension";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        noctalia-qs.inputs = {
          systems.follows = "systems";
          treefmt-nix = {
            follows = "treefmt-nix";
            inputs.nixpkgs.follows = "nixpkgs";
          };
        };
      };
    };
    nix-alien = {
      url = "github:thiagokokada/nix-alien";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Support
    systems.url = "github:nix-systems/default";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    nixpkgs,
    flake-utils,
    home-manager,
    agenix,
    ...
  }: let
    allSystems = flake-utils.lib.defaultSystems;
    flakeLib = import ./lib/flake {
      inherit flake-utils nixpkgs;
    };
    allOutputs = flakeLib.outputsFor allSystems;
    overlays = import ./overlays {inherit inputs;};
    commonModules = [
      home-manager.nixosModules.home-manager
      agenix.nixosModules.default
      ./lib/podman-compose
      ./lib/systemd-user-manager
      flakeLib.serviceModule.portCheckModule
      {nixpkgs.overlays = overlays;}
      {imports = builtins.attrValues (builtins.removeAttrs flakeLib.nixosModules ["default"]);}
      {home-manager.extraSpecialArgs = {inherit inputs;};}
    ];
    mkNixosSystem = flakeLib.mkNixosSystem {
      inherit commonModules inputs;
    };
  in
    flakeLib.standardOutputsFrom allSystems allOutputs
    // {
      # This is intentional, as std packages attr doesn't
      # allow arbitrary nested shape and we expose those
      # in pkgs.
      pkgs = nixpkgs.lib.mapAttrs (_: outputs: outputs.packages) allOutputs;
      inherit (flakeLib) nixosModules;
      overlays.default = nixpkgs.lib.composeManyExtensions overlays;
      nixosConfigurations = import ./hosts {
        inherit mkNixosSystem;
      };
      # Intentional non-standard addition.
      nixosImages = import ./lib/images {
        inherit mkNixosSystem;
      };
    };
}
