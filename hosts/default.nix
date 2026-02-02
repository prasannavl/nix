{
  inputs,
  commonModules,
  ...
}: {
  pvl-a1 = inputs.nixpkgs.lib.nixosSystem {
    system = inputs.flake-utils.lib.system.x86_64-linux;
    specialArgs = {inherit inputs;};
    modules = commonModules ++ [./pvl-a1];
  };
  pvl-x2 = inputs.nixpkgs.lib.nixosSystem {
    system = inputs.flake-utils.lib.system.x86_64-linux;
    specialArgs = {inherit inputs;};
    modules = commonModules ++ [./pvl-x2];
  };
}
