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

    # Every cache kind the module supports, read/write. A kind whose directory
    # is absent is skipped with a warning instead of failing startup, so this
    # also covers caches created after deployment.
    cacheAccess = {
      "cargo-registry" = "rw";
      "cargo-git" = "rw";
      "ccache" = "rw";
      "go-mod" = "rw";
      "go-build" = "rw";
      "gradle" = "rw";
      "maven" = "rw";
      "npm" = "rw";
      "pip" = "rw";
      "pnpm" = "rw";
      "sccache" = "rw";
      "uv" = "rw";
      "yarn" = "rw";
    };
  };
}
