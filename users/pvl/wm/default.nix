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
      kanshi
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
    lib,
    pkgs,
    ...
  }: let
    outputs = import ./outputs.nix;
    wallpaper = ../../../data/backgrounds/sw.png;
    sessionTargets = [
      "niri.service"
      "sway-session.target"
    ];
    mkService = description: execStart: {
      Unit = {
        Description = description;
        PartOf = sessionTargets;
        After = sessionTargets;
      };
      Service = {
        ExecStart = execStart;
        Restart = "on-failure";
        RestartSec = 1;
      };
      Install.WantedBy = sessionTargets;
    };
    renderOutput = output: ''
      output "${output.name}" mode ${output.mode} scale ${output.scale} scale_filter ${output.scaleFilter} subpixel ${output.subpixel} transform ${output.transform}${lib.optionalString output.adaptiveSync " adaptive_sync on"}
    '';
  in {
    home.sessionVariables = {
      XDG_SCREENSHOTS_DIR = "$HOME/Pictures/Screenshots";
    };

    programs.noctalia-shell = {
      enable = true;
    };

    xdg.configFile."kanshi/config".text = ''
      ${lib.concatMapStringsSep "\n" renderOutput outputs.all}

      profile laptop {
        output "${outputs.a1.name}" enable position 0,0
      }

      profile home-lg {
        output "${outputs.a1.name}" enable position 0,320
        output "${outputs.lg-uw3840.name}" enable position 2048,0
      }

      profile home-lg-extra {
        output "${outputs.a1.name}" enable position 0,320
        output "${outputs.lg-uw3840.name}" enable position 2048,0
        output "*" enable
      }
    '';

    systemd.user.services = {
      kanshi =
        mkService
        "Dynamic Output Configuration"
        "${pkgs.kanshi}/bin/kanshi";

      lxqt-policykit =
        mkService
        "LXQt PolicyKit Agent"
        "${pkgs.lxqt.lxqt-policykit}/bin/lxqt-policykit-agent";

      noctalia-shell =
        mkService
        "Noctalia Shell"
        "${config.programs.noctalia-shell.package}/bin/noctalia-shell";

      swaybg =
        mkService
        "Swaybg Wallpaper"
        "${pkgs.swaybg}/bin/swaybg -m fill -i ${wallpaper}";
    };
  };
}
