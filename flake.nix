{
  description = "NixOS Config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:nixos/nixos-hardware";
    vscode-ext = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
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
    };
  };

  outputs = inputs @ {
    nixpkgs,
    flake-utils,
    home-manager,
    agenix,
    ...
  }: let
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
      nixosConfigurations = import ./hosts {
        inherit inputs commonModules;
      };
      nixosImages = import ./lib/images {
        inherit inputs commonModules;
      };
    };
}
