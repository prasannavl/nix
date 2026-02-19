{userdata}: {
  config,
  lib,
  ...
}: {
  # Use the dedicated user group Debian style.
  # NixOS defaults here of users group will break unexpected things
  # like podman, OCI containers in certain configurations.
  users.groups.pvl = {
    # We keep uid and gid the same for simplicity
    gid = userdata.uid;
  };

  users.users.pvl = {
    isNormalUser = true;
    description = userdata.name;
    uid = userdata.uid;
    # Note: Without a dedicated group, podman and OCI containers
    # runtimes with keep-id will not work and will cause misleading
    # permission errors.
    group = userdata.username;
    hashedPassword = userdata.hashedPassword;
    linger = true;
    extraGroups =
      [
        "users"
        "wheel"
        "audio"
        "video"
        "render"
        "netdev"
        "lpadmin"
        "cdrom"
        "floppy"
        "kvm"
      ]
      ++ lib.optional config.security.tpm2.enable "tss"
      ++ lib.optional config.hardware.i2c.enable "i2c"
      ++ lib.optional config.networking.networkmanager.enable "networkmanager"
      ++ lib.optional config.services.seatd.enable "seat"
      ++ lib.optional config.services.keyd.enable "keyd"
      ++ lib.optional config.virtualisation.podman.enable "podman"
      ++ lib.optional config.virtualisation.incus.enable "incus-admin";

    openssh.authorizedKeys.keys = [userdata.sshKey];
    # Home manager pkgs are merged with this
    # we just use that
    packages = [];
  };
}
