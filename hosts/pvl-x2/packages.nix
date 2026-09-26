{pkgs, ...}: {
  environment.systemPackages = [
    pkgs.kodi-wayland
    pkgs.stremio-linux-shell
    pkgs.tuicr
  ];
}
