{...}: {
  imports = [
    ./desktop-gnome-minimal.nix
    ../../ab/system/desktop/gdm-rdp.nix
    ../../ab/system/desktop/flatpak.nix
    ../../ab/system/desktop/printing.nix
  ];
}
