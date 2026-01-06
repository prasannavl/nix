{ config, lib, pkgs, ... }:
{
  # Desktop environment
  services.displayManager.gdm.enable = true;
  services.displayManager.gdm.autoSuspend = false;
  services.desktopManager.gnome.enable = true;
  
  services.desktopManager.gnome.extraGSettingsOverrides = ''
    [org.gnome.mutter]
    experimental-features=['scale-monitor-framebuffer', 'variable-refresh-rate', 'xwayland-native-scaling']
  '';

  programs.dconf.profiles.gdm.databases = [{
    settings = {
      "org/gnome/mutter" = {
        # Empty list disables fractional scaling support
        # experimental-features = lib.mkForce [ ]; 
        experimental-features = [
          "scale-monitor-framebuffer" # Enables fractional scaling (125% 150% 175%)
          "variable-refresh-rate" # Enables Variable Refresh Rate (VRR) on compatible displays
          "xwayland-native-scaling" # Scales Xwayland applications to look crisp on HiDPI screens
        ];
        # Physical mode forces integer-only scaling (1, 2, etc.)
        layout-mode = "physical";
      };
      "org/gnome/desktop/interface" = {
        # Force the UI scaling factor to 1
        scaling-factor = lib.gvariant.mkUint32 1;
      };

      "org/gnome/desktop/remote-desktop/rdp" = {
        enable = true;
        view-only = false;
      };
    };
  }];

  systemd.services."gnome-remote-desktop" = {
    wantedBy = [ "display-manager.service" ];
    after = [ "display-manager.service" ];
  };

  # programs.dconf.profiles.user.databases = [];
}
