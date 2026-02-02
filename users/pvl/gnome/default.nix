{
  config,
  pkgs,
  ...
}: {
  nixos = {};

  home = {
      imports = [
        ./extensions.nix
        ./dconf.nix
        ./keybindings.nix
        ./shell-favorites.nix
        ./clocks-weather.nix
        (import ./wallpaper.nix {
          wallpaperUri = "file://${config.home.homeDirectory}/src/dotfiles/x/files/backgrounds/sw.png";
        })
      ];

      xdg.portal = {
        enable = true;
        extraPortals = [
          pkgs.xdg-desktop-portal-gnome
        ];
        config = {
          gnome = {
            default = ["gnome"];
          };
        };
      };
  };
}
