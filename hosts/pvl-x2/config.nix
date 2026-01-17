{...}: {
  imports = [
    ../../lib/nix.nix
    ../../hosts/pvl-a1/boot.nix
    ../../lib/flatpak.nix
    ../../lib/gnome.nix
    ../../lib/gnome-rdp.nix
    ../../hosts/pvl-a1/locale.nix
    ../../hosts/pvl-a1/misc.nix
    ../../hosts/pvl-a1/network.nix
    ../../lib/network-wireless.nix
    ../../hosts/pvl-a1/packages.nix
    ../../hosts/pvl-a1/programs.nix
    ../../hosts/pvl-a1/security.nix
    ../../hosts/pvl-a1/services.nix
    ../../hosts/pvl-a1/swap.nix
    ../../hosts/pvl-a1/systemd.nix
    ../../hosts/pvl-a1/users.nix
  ];

  networking.hostName = "pvl-x2";
}
