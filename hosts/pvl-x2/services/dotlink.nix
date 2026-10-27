{inputs, ...}: {
  imports = [inputs.dotlink.nixosModules.default];

  services.dotlink = {
    enable = true;
    user = "pvl";
    # Source checkout root on pvl-x2; created so WorkingDirectory exists.
    workingDirectory = "/home/pvl/src/";
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

  # The launch directory is not optional for systemd; create it on activation.
  systemd.tmpfiles.rules = [
    "d /home/pvl/src 0755 pvl pvl -"
  ];
}
