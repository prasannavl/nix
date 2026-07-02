{
  pkgs ?
    import <nixpkgs> {
      config.allowUnfree = true;
    },
}: let
  incusTests = import ../incus/tests {pkgs = pkgs;};
  podmanComposeTests = import ../podman-compose/tests {inherit pkgs;};
  stalwartLib = import ../services/stalwart {inherit pkgs;};
  stalwartTests = import ../services/stalwart/tests {
    inherit pkgs;
    inherit (stalwartLib) mkUserdataProvisioning;
  };
  systemdUserManagerTests = import ../systemd-user-manager/tests {pkgs = pkgs;};
in {
  lib-incus-helper = incusTests.helper;
  lib-incus-module = incusTests.module;
  lib-podman-compose-helper = podmanComposeTests.helper;
  lib-podman-compose-module = podmanComposeTests.module;
  lib-profiles-incus-lxc = import ./profiles-incus-lxc.nix {inherit pkgs;};
  lib-stalwart-helper = stalwartTests.helper;
  lib-stalwart-provisioning = stalwartTests.provisioning;
  lib-systemd-user-manager-helper = systemdUserManagerTests.helper;
  lib-systemd-user-manager-module = systemdUserManagerTests.module;
}
