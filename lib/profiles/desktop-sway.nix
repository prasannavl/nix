{...}: {
  imports = [
    ./desktop-core.nix
    # ../seatd.nix
  ];

  programs.sway.enable = true;

  xdg.portal = {
    enable = true;
    extraPortals = [pkgs.xdg-desktop-portal-wlr];
    config.common.default = "wlr";
  };
}
