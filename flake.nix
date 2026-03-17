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
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "home-manager";
      inputs.systems.follows = "systems";
    };
    nixos-hardware.url = "github:nixos/nixos-hardware";
    vscode-ext = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.systems.follows = "systems";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };
    antigravity = {
      url = "github:jacopone/antigravity-nix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    codex = {
      url = "github:openai/codex/b9904c0ae4ecb773549efd6ea3fb05229402fdb9";
      inputs.nixpkgs.follows = "nixpkgs";
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
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.noctalia-qs.inputs.systems.follows = "systems";
      inputs.noctalia-qs.inputs.treefmt-nix.follows = "treefmt-nix";
      inputs.noctalia-qs.inputs.treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
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
    packageOutputsFor = import ./pkgs {
      inherit nixpkgs flake-utils;
    };
    packageTreeFor = system: (packageOutputsFor.outputsForSystem system).packageTree.pkgs;
    overlays = import ./overlays {inherit inputs;};
    commonModules = [
      home-manager.nixosModules.home-manager
      agenix.nixosModules.default
      {nixpkgs.overlays = overlays;}
      {home-manager.extraSpecialArgs = {inherit inputs;};}
    ];
    formatterPkgsFor = pkgs:
      with pkgs; [
        treefmt
        alejandra
        deno
        opentofu
      ];
  in
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      formatterPkgs = formatterPkgsFor pkgs;
    in {
      formatter = pkgs.writeShellApplication {
        name = "treefmt";
        runtimeInputs = formatterPkgs;
        text = "treefmt";
      };
    })
    // {
      pkgs = nixpkgs.lib.genAttrs flake-utils.lib.defaultSystems packageTreeFor;
      overlays.default = nixpkgs.lib.composeManyExtensions overlays;
      nixosConfigurations = import ./hosts {
        inherit inputs commonModules;
      };
      nixosImages = import ./lib/images {
        inherit inputs commonModules;
      };
    };
}
