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

  pvl-vlab = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inputs = inputs;
      hostName = "pvl-vlab";
    };
    modules = commonModules ++ [./pvl-vlab];
  };

  pvl-vkamino = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inputs = inputs;
      hostName = "pvl-vkamino";
    };
    modules = commonModules ++ [./pvl-vkamino];
  };

  gap3-gondor = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inputs = inputs;
      hostName = "gap3-gondor";
    };
    modules = commonModules ++ [./gap3-gondor];
  };
}
