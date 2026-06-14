{...}: {
  imports = [
    ../common/pvl.nix
    ../../lib/devices/asus-fa401wv.nix
    ./sys.nix
    ./nix-ld.nix
    ./packages.nix
    ./firewall.nix
    ./users.nix
    ./services
    ./incus.nix
  ];

  # hw gets stuck on suspend, and triggers watchdog and reboots, even though
  # userspace is frozen correctly, but still has kernel issues. This helps
  # sleep move into lower power state, even if resume isn't always
  # reliable.
  x.panicReboot = 0;

  services.fail2ban.enable = true;
}
