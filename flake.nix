{
  description = "NixOS Config";
  
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llm-agents = { 
      url = "github:numtide/llm-agents.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    antigravity = {
      url = "github:jacopone/antigravity-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    p7-borders = {
      url = "path:/home/pvl/src/pvl/p7-borders";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    p7-cmds = {
      url = "path:/home/pvl/src/pvl/p7-cmds";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixos-hardware.url = "github:nixos/nixos-hardware";
    vscode-ext = { 
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, llm-agents, antigravity, vscode-ext, ... }@inputs: {
    nixosConfigurations.pvl-a1 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        home-manager.nixosModules.home-manager
        {
          nixpkgs.overlays = [ 
            # (import ./overlays/unstable-sys.nix { inherit inputs; })
            (import ./overlays/unstable.nix { inherit inputs; })
            inputs.vscode-ext.overlays.default 
            (import ./overlays/pvl.nix { inherit inputs; }) 
          ]; 
        }
        ./config.nix
      ];
    };
  };
}
