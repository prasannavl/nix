{...}: {
  imports = [
    ./desktop-gnome-minimal.nix
    ../gdm-rdp.nix
    ../flatpak.nix
    ../printing.nix
    ../handbrake.nix
  ];
}
