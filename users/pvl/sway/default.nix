{
  nixos = {pkgs, ...}: {
    programs.sway.enable = true;
    programs.sway.wrapperFeatures.gtk = true;
    
    environment.systemPackages = with pkgs; [
      swayidle
      swaylock
      foot
      dmenu
      wdisplays
    ];
  };

  home = {pkgs, ...}: {
    # home manager rebinds alt as Mod4 key
    # and others to keep it i3 compat. 
    # wayland.windowManager.sway.enable = true;

    xdg.portal = {
      enable = true;
      extraPortals = [
        pkgs.xdg-desktop-portal-wlr
        pkgs.xdg-desktop-portal-gtk
      ];
      config = {
        common.default = "gtk";
        sway = {
          default = ["wlr" "gtk"];
        };
      };
    };

    # Setting this causes gnome's
    # xwayland-native-scaling to not work well.
    # cursor sizes are double divided.
    #
    # home.pointerCursor = {
    #   name = "Adwaita";
    #   package = pkgs.adwaita-icon-theme;
    #   size = 24;
    #   x11.enable = true;
    #   # dotIcons.enable = true;
    # };

    programs.noctalia-shell = {
      enable = true;
    };
  };
}
