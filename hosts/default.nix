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

  pvl-vk = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = {
      inputs = inputs;
      hostName = "pvl-vk";
    };
    modules = commonModules ++ [./pvl-vk];
  };

  # This host is taken over by gap3 repo. This configuration is kept here
  # purely only for ref and backup.
  #
  # gap3-gondor = nixpkgs.lib.nixosSystem {
  #   system = "x86_64-linux";
  #   specialArgs = {
  #     inputs = inputs;
  #     hostName = "gap3-gondor";
  #   };
  #   modules = commonModules ++ [./gap3-gondor];
  # };
}
