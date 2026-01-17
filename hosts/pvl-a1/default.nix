{
  inputs,
  system,
  ...
}:
  inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = {inherit inputs;};
    modules = [
      inputs.home-manager.nixosModules.home-manager
      {
        nixpkgs.overlays = [
          # (import ./overlays/unstable-sys.nix { inherit inputs; })
          (import ../../overlays/unstable.nix {inherit inputs;})
          inputs.vscode-ext.overlays.default
          (import ../../overlays/pvl.nix {inherit inputs;})
        ];
      }
      ./config.nix
    ];
  }
