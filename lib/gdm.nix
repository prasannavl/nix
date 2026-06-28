{
  lib,
  pkgs,
  ...
}: {
  services.displayManager.gdm.enable = true;
  services.displayManager.gdm.autoSuspend = false;

  programs.dconf.profiles.gdm.databases = [
    {
      settings = {
        "org/gnome/mutter" = {
          # Empty list disables fractional scaling support
          # experimental-features = lib.mkForce [ ];
          experimental-features = [
            "scale-monitor-framebuffer"
            "xwayland-native-scaling"
          ];
          # Physical mode forces integer-only scaling (1, 2, etc.)
          layout-mode = "physical";
        };
        "org/gnome/desktop/interface" = {
          # Force the UI scaling factor to 1
          scaling-factor = lib.gvariant.mkUint32 1;
        };
      };
    }
  ];
}
