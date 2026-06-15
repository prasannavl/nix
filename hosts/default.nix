{
  mkNixosSystem,
  stacks,
  ...
}: let
  mkPvlHost = args:
    mkNixosSystem (args // {stack = stacks.pvl;});
in {
  pvl-a1 = mkPvlHost {
    hostName = "pvl-a1";
    modules = [./pvl-a1];
  };

  pvl-x2 = mkPvlHost {
    hostName = "pvl-x2";
    modules = [./pvl-x2];
  };

  pvl-l5 = mkPvlHost {
    hostName = "pvl-l5";
    modules = [./pvl-l5];
  };

  pvl-vlab = mkPvlHost {
    hostName = "pvl-vlab";
    modules = [./pvl-vlab];
  };

  pvl-vlab-1 = mkPvlHost {
    hostName = "pvl-vlab-1";
    modules = [./pvl-vlab-1];
  };

  pvl-vk = mkPvlHost {
    hostName = "pvl-vk";
    modules = [./pvl-vk];
  };

  pvl-vk-1 = mkPvlHost {
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
