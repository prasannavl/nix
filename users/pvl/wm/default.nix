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
    wmScripts = wmServices.mkWmScripts pkgs;
  in {
    home.sessionVariables = {
      XDG_SCREENSHOTS_DIR = "$HOME/Pictures/Screenshots";
    };

    programs.noctalia-shell = {
      enable = true;
    };

    systemd.user = {
      targets."${wmServices.readyTargets.niri}".Unit = {
        Description = "WM session display-ready target";
        BindsTo = [wmServices.sessionUnits.niri];
        PartOf = [wmServices.sessionUnits.niri];
        After = [wmServices.sessionUnits.niri];
      };

      targets."${wmServices.readyTargets.sway}".Unit = {
        Description = "WM session display-ready target";
        BindsTo = [wmServices.sessionUnits.sway];
        PartOf = [wmServices.sessionUnits.sway];
        After = [wmServices.sessionUnits.sway];
      };

      services = {
        portal-cleanup = {
          Unit = {
            Description = "Prepare and cleanup XDG Desktop Portal units";
            Before = wmServices.allReadyTargets;
            After = wmServices.sessionTargets;
            PartOf = wmServices.allReadyTargets ++ wmServices.sessionTargets;
          };
          Service = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.lib.getExe wmScripts.preparePortals;
            ExecStop = pkgs.lib.getExe wmScripts.portalCleanup;
          };
          Install.WantedBy = wmServices.allReadyTargets;
        };

        lxqt-policykit =
          wmServices.mkWmPostService
          "LXQt PolicyKit Agent"
          "${pkgs.lxqt.lxqt-policykit}/bin/lxqt-policykit-agent";

        noctalia-shell =
          wmServices.mkWmPostService
          "Noctalia Shell"
          "${config.programs.noctalia-shell.package}/bin/noctalia-shell";

        swaybg =
          wmServices.mkWmPostService
          "Swaybg Wallpaper"
          "${pkgs.swaybg}/bin/swaybg -m fill -i ${wallpaper}";
      };
    };
  };
}
