{
  nixos = {...}: {};

  home = {pkgs, ...}: let
    sessionTargets = [
      "graphical-session.target"
      "niri.service"
      "sway-session.target"
    ];
  in {
    imports = [
      ./extensions.nix
      ./dconf.nix
      ./apps.nix
      ./keybindings.nix
      ./shell-favorites.nix
      ./clocks-weather.nix
      (import ./wallpaper.nix {
        wallpaperUri = "file://${../../../data/backgrounds/sw.png}";
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

    # GOA talks to a login-session keyring, so keep it session-scoped instead of
    # letting D-Bus leave it attached to the long-lived user manager across
    # session churn.
    #
    # References:
    # - Launchpad #1695775: GOA can break after logout until reboot when the
    #   daemon survives longer than the session-scoped keyring.
    #   https://bugs.launchpad.net/bugs/1695775
    # - Launchpad #1610944 / GNOME #764029: related GOA logout/session lifetime
    #   bugs around the daemon not being stopped cleanly with the session.
    #   https://bugs.launchpad.net/bugs/1610944
    #   https://bugzilla.gnome.org/show_bug.cgi?id=764029
    systemd.user.services."org.gnome.OnlineAccounts" = {
      Unit = {
        Description = "GNOME Online Accounts";
        PartOf = sessionTargets;
        After = sessionTargets;
      };
      Service = {
        Type = "dbus";
        BusName = "org.gnome.OnlineAccounts";
        ExecStart = "${pkgs.gnome-online-accounts}/libexec/goa-daemon";
        Restart = "on-failure";
      };
      Install.WantedBy = sessionTargets;
    };
  };
}
