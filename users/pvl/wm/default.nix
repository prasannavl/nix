{
  nixos = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      alacritty
      foot
      ghostty
      brightnessctl
      fuzzel
      wmenu
      dmenu
      lxqt.lxqt-policykit
      pulseaudio
      pavucontrol
      playerctl
      wireplumber
      wdisplays
      swaybg
      swaylock
      swayidle
      wl-clipboard
      grim
      slurp
      sway-contrib.grimshot
      lswt
      gpu-screen-recorder
      gpu-screen-recorder-gtk
      xdg-utils
      xdg-user-dirs
      xdg-desktop-portal-gtk
    ];

    qt = {
      enable = true;
      platformTheme = "qt5ct";
    };
  };

  home = {
    config,
    pkgs,
    ...
  }: let
    wallpaper = ../../../data/backgrounds/sw.png;
    wmServices = import ./services.nix {};
  in {
    home.sessionVariables = {
      XDG_SCREENSHOTS_DIR = "$HOME/Pictures/Screenshots";
    };

    programs.noctalia-shell = {
      enable = true;
    };

    systemd.user.services = {
      lxqt-policykit =
        wmServices.mkWmService
        "LXQt PolicyKit Agent"
        "${pkgs.lxqt.lxqt-policykit}/bin/lxqt-policykit-agent";

      noctalia-shell =
        wmServices.mkWmService
        "Noctalia Shell"
        "${config.programs.noctalia-shell.package}/bin/noctalia-shell";

      swaybg =
        wmServices.mkWmService
        "Swaybg Wallpaper"
        "${pkgs.swaybg}/bin/swaybg -m fill -i ${wallpaper}";
    };
  };
}
