{...}: {
  imports = [
    ../../lib/nix.nix
    ./boot.nix
    ../../lib/flatpak.nix
    ../../lib/gnome.nix
    ../../lib/gnome-rdp.nix
    ./locale.nix
    ./misc.nix
    ./network.nix
    ../../lib/network-wireless.nix
    ./packages.nix
    ./programs.nix
    ./security.nix
    ./services.nix
    ./swap.nix
    ./systemd.nix
    ./users.nix
    ./sys.nix
    ../../hardware/asus-fa401wv.nix
  ];

  networking.hostName = "pvl-a1";

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11";
}
