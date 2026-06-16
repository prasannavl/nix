{
  inputProfiles,
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
}
