{
  mkNixosSystem,
  stacks,
  ...
}: let
  mkPvlSystem = args:
    mkNixosSystem (args // {stack = stacks.pvl;});
in {
  pvl-a1 = mkPvlSystem {
    system = "x86_64-linux";
    hostName = "pvl-a1";
    modules = [./pvl-a1];
  };

  pvl-x2 = mkPvlSystem {
    system = "x86_64-linux";
    hostName = "pvl-x2";
    modules = [./pvl-x2];
  };

  pvl-vlab = mkPvlSystem {
    system = "x86_64-linux";
    hostName = "pvl-vlab";
    modules = [./pvl-vlab];
  };

  pvl-vlab-1 = mkPvlSystem {
    system = "x86_64-linux";
    hostName = "pvl-vlab-1";
    modules = [./pvl-vlab-1];
  };

  pvl-vk = mkPvlSystem {
    system = "x86_64-linux";
    hostName = "pvl-vk";
    modules = [./pvl-vk];
  };

  pvl-vk-1 = mkPvlSystem {
    system = "x86_64-linux";
    hostName = "pvl-vk-1";
    modules = [./pvl-vk-1];
  };

  # This host is taken over by gap3 repo. This configuration is kept here
  # purely only for ref and backup.
  #
  # gap3-gondor = mkNixosSystem {
  #   system = "x86_64-linux";
  #   hostName = "gap3-gondor";
  #   modules = [./gap3-gondor];
  # };
}
