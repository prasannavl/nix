{inputs, ...}: {
  imports = [inputs.dotlink.nixosModules.default];

  services.dotlink = {
    enable = true;
    user = "pvl";
    workingDirectory = "/home/pvl/spaces/abird/";
    logging.verbosity = "tools";

    # Host integrations for Bubblewrap shell tools: host Nix daemon and Nix
    # config, Git config, and the SSH agent (GCR) socket. These map to the
    # module's --allow-nix-daemon/--allow-nix-config/--allow-git-config/
    # --allow-ssh-agent flags; --allow-shell is added automatically. Shell
    # network access remains enabled via the saved profile.
    hostAccess = {
      nixDaemon = true;
      nixConfig = true;
      gitConfig = true;
      sshAgent = true;
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
