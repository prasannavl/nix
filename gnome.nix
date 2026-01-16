{
  config,
  lib,
  pkgs,
  ...
}: {
  # Desktop environment
  services.displayManager.gdm.enable = true;
  services.displayManager.gdm.autoSuspend = false;

  services.desktopManager.gnome.enable = true;
  services.desktopManager.gnome.extraGSettingsOverrides = ''
    [org.gnome.mutter]
    experimental-features=['scale-monitor-framebuffer', 'variable-refresh-rate', 'xwayland-native-scaling']
  '';

  services.gnome.gnome-remote-desktop.enable = true;

  # The following should be automatically set, but we're
  # being explicit.
  services.gnome.core-apps.enable = true;
  services.gnome.gnome-keyring.enable = true;
  # services.gnome.gnome-online-accounts.enable = true;
  services.gvfs.enable = true;
  services.udev.packages = [ pkgs.gnome-settings-daemon ];

  # Gnome using wsdd for Windows network discovery
  services.samba-wsdd.enable = true;
  services.samba-wsdd.openFirewall = true;

  programs.dconf.profiles.gdm.databases = [
    {
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
    }
  ];

  systemd.services.gnome-remote-desktop = {
    wantedBy = ["display-manager.service"];
    after = ["display-manager.service"];
    serviceConfig = {
      Environment = [
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
        "SHELL=/run/current-system/sw/bin/bash"
        "XDG_DATA_DIRS=/run/current-system/sw/share"
      ];
    };
  };

  systemd.services.gnome-remote-desktop-configuration = {
    serviceConfig = {
      Environment = [
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
        "SHELL=/run/current-system/sw/bin/bash"
        "XDG_DATA_DIRS=/run/current-system/sw/share"
      ];
    };
  };

  # programs.dconf.profiles.user.databases = [];

  xdg.portal = {
    enable = true;
    extraPortals = [pkgs.xdg-desktop-portal-gnome];
    config.common.default = "gnome";
  };
}
