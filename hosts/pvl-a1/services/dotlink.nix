{inputs, ...}: {
  imports = [inputs.dotlink.nixosModules.default];

  services.dotlink = {
    enable = true;
    user = "pvl";
    workingDirectory = "/home/pvl/spaces/abird/";
    logging.verbosity = "tools";

    # Host integrations for Bubblewrap shell tools; maps to --allow-* flags.
    # --allow-shell is added automatically, shell network comes from the
    # saved profile.
    hostAccess = {
      nixDaemon = true;
      nixConfig = true;
      gitConfig = true;
      sshAgent = true;
      # /dev/kvm (AMD-V) plus AMD and NVIDIA GPU devices/driver resources.
      kvm = true;
      gpu = ["amd" "nvidia"];
    };

    # Shell-only developer caches discovered on both hosts, read/write.
    cacheAccess = {
      "cargo-registry" = "rw";
      "cargo-git" = "rw";
      "npm" = "rw";
      "yarn" = "rw";
      "pip" = "rw";
      "go-mod" = "rw";
      "go-build" = "rw";
    };
  };
}
