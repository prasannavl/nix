{
  lib,
  pkgs,
  ...
}: {
  imports = [
    ../../lib/devices/asus-fa401wv.nix
    ../../lib/swap-auto.nix
    ../../lib/profiles/all.nix
    ./sys.nix
    ./packages.nix
    ./firewall.nix
    ./podman.nix
    ./users.nix
  ];

  # hw gets stuck on suspend, and triggers watchdog and reboots, even though
  # userspace is frozen correctly, but still has kernel issues. This helps
  # sleep move into lower power state, even if resume isn't always
  # reliable.
  x.panicReboot = 0;
}
