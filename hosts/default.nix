{
  inputs,
  commonModules,
  ...
}: let
  inherit (inputs) nixpkgs;
in {
  pvl-a1 = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inputs = inputs;
      hostName = "pvl-a1";
    };
    modules = commonModules ++ [./pvl-a1];
  };

  pvl-x2 = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inputs = inputs;
      hostName = "pvl-x2";
    };
    modules = commonModules ++ [./pvl-x2];
  };

  llmug-rivendell = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inputs = inputs;
      hostName = "llmug-rivendell";
    };
    modules = commonModules ++ [./llmug-rivendell];
  };

  gap3-gondor = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inputs = inputs;
      hostName = "gap3-gondor";
    };
    modules = commonModules ++ [./gap3-gondor];
  };

  gap3-rivendell = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inputs = inputs;
      hostName = "gap3-rivendell";
    };
    modules = commonModules ++ [./gap3-rivendell];
  };
}
