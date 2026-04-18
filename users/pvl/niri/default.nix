{
  nixos = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      alacritty
      brightnessctl
      fuzzel
      lxqt.lxqt-policykit
      niri
      playerctl
      pulseaudio
      shikane
      swaybg
      swaylock
      wireplumber
      wmenu
      wl-clipboard
      xdg-desktop-portal-gnome
      xdg-desktop-portal-gtk
      xdg-utils
      xdg-user-dirs
      xwayland-satellite
    ];

    security.pam.services.login.enableGnomeKeyring = true;

    services.gnome = {
      gnome-keyring.enable = true;
      gcr-ssh-agent.enable = true;
    };

    # Disable other known agents when using gcr-ssh-agent.
    programs.gnupg.agent.enableSSHSupport = false;
    programs.ssh.startAgent = false;
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
        pkgs.xdg-desktop-portal-gnome
        pkgs.xdg-desktop-portal-gtk
      ];
      config = {
        common.default = "gtk";
        niri = {
          default = ["gnome" "gtk"];
        };
      };
    };

    programs.noctalia-shell = {
      enable = true;
    };

    systemd.user.services = {
      niri-lxqt-policykit = {
        Unit = {
          Description = "LXQt PolicyKit Agent for Niri";
          PartOf = ["graphical-session.target"];
          After = ["graphical-session.target"];
          Requisite = ["graphical-session.target"];
        };
        Service = {
          ExecStart = "${pkgs.lxqt.lxqt-policykit}/bin/lxqt-policykit-agent";
          Restart = "on-failure";
          RestartSec = 1;
        };
        Install.WantedBy = ["niri.service"];
      };

      niri-shikane = {
        Unit = {
          Description = "Shikane Output Profile Daemon for Niri";
          PartOf = ["graphical-session.target"];
          After = ["graphical-session.target"];
          Requisite = ["graphical-session.target"];
        };
        Service = {
          ExecStart = "${pkgs.shikane}/bin/shikane";
          Restart = "on-failure";
          RestartSec = 1;
        };
        Install.WantedBy = ["niri.service"];
      };

      niri-noctalia-shell = {
        Unit = {
          Description = "Noctalia Shell for Niri";
          PartOf = ["graphical-session.target"];
          After = ["graphical-session.target"];
          Requisite = ["graphical-session.target"];
        };
        Service = {
          ExecStart = "${config.programs.noctalia-shell.package}/bin/noctalia-shell";
          Restart = "on-failure";
          RestartSec = 1;
        };
        Install.WantedBy = ["niri.service"];
      };
    };
  };
}
