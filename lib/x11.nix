{pkgs, ...}: {
  services.xserver.enable = true;
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };
  # Enable touchpad support (enabled default in most desktopManager).
  services.xserver.libinput.enable = true;
}
