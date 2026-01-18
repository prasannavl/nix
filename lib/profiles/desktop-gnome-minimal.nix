{...}: {
  imports = [
    ./desktop-core.nix
    ../audio.nix
    ../graphics.nix
    ../x11.nix
    ../gdm.nix
    ../gnome.nix
  ];
}
