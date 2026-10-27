{inputs, ...}: {
  imports = [inputs.dotlink.nixosModules.default];

  services.dotlink = {
    enable = true;
    user = "pvl";
    # pvl-x2 has no source checkout yet; ~/Projects is the access root.
    workingDirectory = "/home/pvl/Projects/";
    logging.verbosity = "tools";

    # Host integrations for Bubblewrap shell tools; maps to --allow-* flags.
    # --allow-shell is added automatically, shell network comes from the
    # saved profile.
    hostAccess = {
      nixDaemon = true;
      nixConfig = true;
      gitConfig = true;
      sshAgent = true;
      # /dev/kvm plus the AMD (Strix Halo) GPU devices/driver resources.
      # pvl-x2 is AMD-only, so there is no NVIDIA grant.
      kvm = true;
      gpu = ["amd"];
    };

    # Only caches that already exist on pvl-x2; read/write.
    cacheAccess = {
      "pip" = "rw";
    };
  };
}
