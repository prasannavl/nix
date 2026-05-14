{mkNixosSystem, ...}: {
  pvl-a1 = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "pvl-a1";
    modules = [./pvl-a1];
  };

  pvl-x2 = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "pvl-x2";
    modules = [./pvl-x2];
  };

  pvl-vlab = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "pvl-vlab";
    modules = [./pvl-vlab];
  };

  pvl-vlab-1 = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "pvl-vlab-1";
    modules = [./pvl-vlab-1];
  };

  pvl-vk = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "pvl-vk";
    modules = [./pvl-vk];
  };

  pvl-vk-1 = mkNixosSystem {
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
