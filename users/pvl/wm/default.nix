let
  terminal = pkgs: import ./terminal.nix {pkgs = pkgs;};
in {
  nixos = {pkgs, ...}: {
    environment.systemPackages = with pkgs;
      [
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
      ]
      ++ [(terminal pkgs).package];

    qt = {
      enable = true;
      platformTheme = "qt5ct";
    };
  };

  home = {
    osConfig,
    pkgs,
    ...
  }: let
    wallpaper = ../../../data/backgrounds/sw.png;
    wmServices = import ./services.nix {};
    wmScripts = wmServices.mkWmScripts pkgs;
    ibus = "${osConfig.i18n.inputMethod.package}/bin/ibus";
  in {
    # Override NixOS's IBus autostart command for both Wayland sessions.
    # GNOME retains its own IBus service.
    xdg.configFile."autostart/ibus-daemon.desktop".text = ''
      [Desktop Entry]
      Type=Application
      Name=IBus Wayland
      Exec=${ibus} start --type wayland
      OnlyShowIn=niri;sway;
      NoDisplay=true
    '';

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

        swaybg =
          wmServices.mkWmPostService
          "Swaybg Wallpaper"
          "${pkgs.swaybg}/bin/swaybg -m fill -i ${wallpaper}";
      };
    };
  };
}
