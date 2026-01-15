{
  config,
  pkgs,
  lib,
  ...
}: let
  userdata = (import ../userdata.nix).pvl;
in {
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
    extraGroups = [
      "users"
      "networkmanager"
      "wheel"
      "tss"
      "seat"
      "i2c"
      "podman"
      "keyd"
      "incus-admin"
    ];
    openssh.authorizedKeys.keys = [userdata.sshKey];
    # Home manager pkgs are merged with this
    # we just use that
    packages = [];
  };

  home-manager.users.pvl = import ./home.nix;
}
