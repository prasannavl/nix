{
  nixos = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      alacritty
      foot
      ghostty
      niri
      wl-clipboard
      xdg-utils
      xdg-user-dirs
      sway
      fuzzel
      wmenu
      xdg-desktop-portal-wlr
      wdisplays
      swayidle
      swaylock
      dmenu
      sway-contrib.grimshot
      grim
      slurp
      brightnessctl
      pavucontrol
      lxqt.lxqt-policykit
      pulseaudio
      shikane
    ];
  };

  home = {
    config,
    pkgs,
    ...
  }: {
    imports = [
      ./config.nix
    ];

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

    programs.noctalia-shell = {
      enable = true;
    };

    systemd.user.services = {
      sway-lxqt-policykit = {
        Unit = {
          Description = "LXQt PolicyKit Agent for Sway";
          PartOf = ["sway-session.target"];
          After = ["sway-session.target"];
        };
        Service = {
          ExecStart = "${pkgs.lxqt.lxqt-policykit}/bin/lxqt-policykit-agent";
          Restart = "on-failure";
          RestartSec = 1;
        };
        Install.WantedBy = ["sway-session.target"];
      };

      sway-shikane = {
        Unit = {
          Description = "Shikane Output Profile Daemon for Sway";
          PartOf = ["sway-session.target"];
          After = ["sway-session.target"];
        };
        Service = {
          ExecStart = "${pkgs.shikane}/bin/shikane";
          Restart = "on-failure";
          RestartSec = 1;
        };
        Install.WantedBy = ["sway-session.target"];
      };

      sway-noctalia-shell = {
        Unit = {
          Description = "Noctalia Shell for Sway";
          PartOf = ["sway-session.target"];
          After = ["sway-session.target"];
        };
        Service = {
          ExecStart = "${config.programs.noctalia-shell.package}/bin/noctalia-shell";
          Restart = "on-failure";
          RestartSec = 1;
        };
        Install.WantedBy = ["sway-session.target"];
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
  };
}
