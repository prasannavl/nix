{
  lib,
  pkgs,
  ...
}: {
  services.hardware.openrgb.enable = true;
  services.udev.packages = [pkgs.openrgb];
}
