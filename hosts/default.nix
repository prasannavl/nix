{
  inputs,
  commonModules,
  ...
}: let 
  nixpkgs = inputs.nixpkgs;
  flake-utils = inputs.flake-utils; 
in {
  pvl-a1 = nixpkgs.lib.nixosSystem {
    system = flake-utils.lib.system.x86_64-linux;
    specialArgs = {inherit inputs;};
    modules = commonModules ++ [./pvl-a1];
  };
  pvl-x2 = nixpkgs.lib.nixosSystem {
    system = flake-utils.lib.system.x86_64-linux;
    specialArgs = {inherit inputs;};
    modules = commonModules ++ [./pvl-x2];
  };
}
