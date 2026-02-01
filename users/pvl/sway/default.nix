{
  config,
  pkgs,
  ...
}: {
  wayland.windowManager.sway.enable = true;

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

  home.pointerCursor = {
    name = "Adwaita";
    package = pkgs.adwaita-icon-theme;
    size = 24;
    x11 = {
      enable = true;
      defaultCursor = "Adwaita";
    };
  };

  programs.noctalia-shell = {
    enable = true;
  };
}
