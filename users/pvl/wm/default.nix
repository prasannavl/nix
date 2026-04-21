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

      # Stop stale portal backends from the previous WM before the new Sway or
      # Niri session starts so portal activation picks the correct backend after
      # compositor switches.
      portal-cleanup = let
        portalCleanupBin = pkgs.writeShellApplication {
          name = "portal-cleanup";
          runtimeInputs = [
            pkgs.systemd
          ];
          text = ''
            set -Eeuo pipefail

            units=(
              xdg-desktop-portal.service
              xdg-desktop-portal-gtk.service
              xdg-desktop-portal-gnome.service
              xdg-desktop-portal-wlr.service
            )

            for unit in "''${units[@]}"; do
              systemctl --user stop "$unit" 2>/dev/null || true
            done
          '';
        };
      in
        wmServices.mkWmPreService
        "Stop stale XDG Desktop Portal units"
        "${portalCleanupBin}/bin/portal-cleanup";
    };
  };
}
