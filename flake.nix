{
  description = "NixOS Config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    sway-git = {
      url = "github:swaywm/sway?ref=master";
      flake = false;
    };
    wlroots-git = {
      url = "git+https://gitlab.freedesktop.org/wlroots/wlroots?ref=master";
      flake = false;
    };
    xdg-desktop-portal-wlr-git = {
      url = "github:emersion/xdg-desktop-portal-wlr?ref=master";
      flake = false;
    };
    xdg-desktop-portal-git = {
      url = "github:flatpak/xdg-desktop-portal?ref=main";
      flake = false;
    };
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
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
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
    devShellsLib = import ./lib/flake/dev-shells.nix {
      inherit (nixpkgs) lib;
    };
    devShellsFor = system: let
      pkgs = import nixpkgs {
        inherit system;
        overlays = overlays;
      };
      rootPackages = [
        pkgs.alejandra
        pkgs.git
        pkgs.jq
        pkgs.nix
        pkgs.nix-output-monitor
        pkgs.nvd
        agenix.packages.${system}.default
      ];
      childPackages = allOutputs.${system}.packages;
    in
      devShellsLib.mkDevShells {
        inherit pkgs rootPackages childPackages;
      };
  in
    flakeLib.standardOutputsFrom allSystems allOutputs
    // {
      devShells = nixpkgs.lib.genAttrs allSystems devShellsFor;
    }
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
