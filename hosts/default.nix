{
  inputs,
  commonModules,
  ...
}: let
  nixpkgs = inputs.nixpkgs;
in {
  pvl-a1 = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostName = "pvl-a1";
    };
    modules = commonModules ++ [./pvl-a1];
  };

  pvl-x2 = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostName = "pvl-x2";
    };
    modules = commonModules ++ [./pvl-x2];
  };

  llmug-rivendell = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inherit inputs;
      hostName = "llmug-rivendell";
    };
    modules = commonModules ++ [./llmug-rivendell];
  };
}
