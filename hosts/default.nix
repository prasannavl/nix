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
    inputProfile = inputProfiles.next;
  };

  pvl-l5 = mkPvlHost {
    hostName = "pvl-l5";
    modules = [./pvl-l5];
    inputProfile = inputProfiles.next;
  };

  pvl-vlab = mkPvlHost {
    hostName = "pvl-vlab";
    modules = [./pvl-vlab];
    inputProfile = inputProfiles.next;
  };

  pvl-vlab-1 = mkPvlHost {
    hostName = "pvl-vlab-1";
    modules = [./pvl-vlab-1];
    inputProfile = inputProfiles.next;
  };

  pvl-vk = mkPvlHost {
    hostName = "pvl-vk";
    modules = [./pvl-vk];
    inputProfile = inputProfiles.next;
  };

  pvl-vk-1 = mkPvlHost {
    hostName = "pvl-vk-1";
    modules = [./pvl-vk-1];
    inputProfile = inputProfiles.next;
  };
}
