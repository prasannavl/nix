{
  lib,
  pkgs,
  ...
}: let
  mutterLessThan50 = version: lib.versionOlder version "50";
in {
  services.displayManager.gdm.enable = true;
  services.displayManager.gdm.autoSuspend = false;

  programs.dconf.profiles.gdm.databases = [
    {
      settings = {
        "org/gnome/mutter" = {
          # Empty list disables fractional scaling support
          # experimental-features = lib.mkForce [ ];
          experimental-features = let
            features =
              [
                "scale-monitor-framebuffer"
                "xwayland-native-scaling"
              ]
              ++ lib.optional (mutterLessThan50 pkgs.mutter.version) "variable-refresh-rate";
          in
            features;
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
