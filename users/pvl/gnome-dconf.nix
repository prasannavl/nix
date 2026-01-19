{lib, ...}: let
  gvariant = lib.gvariant;
in {
  dconf = {
    enable = true;
    settings = {
      "org/gnome/shell" = {
        disable-user-extensions = false;
        disabled-extensions = [];
      };
      "org/gnome/settings-daemon/plugins/power" = {
        sleep-inactive-ac-type = "nothing";
      };
      "org/gnome/desktop/session" = {
        # Idle timeout (seconds)
        idle-delay = gvariant.mkUint32 480;
      };
      "org/gnome/desktop/wm/preferences" = {
        "button-layout" = ":minimize,maximize,close";
      };
      "org/gnome/desktop/sound" = {
        allow-volume-above-100-percent = true;
      };
      "org/gnome/desktop/a11y" = {
        always-show-universal-access-status = true;
      };
      "org/gnome/desktop/remote-desktop/rdp" = {
        enable = true;
        view-only = false;
      };
      "org/gnome/desktop/interface" = {
        color-scheme = "prefer-dark";
        # accent-color = "blue";
        clock-format = "12h";
        clock-show-seconds = true;
        clock-show-weekday = true;
        # enable-animations = true;
        # enable-hot-corners = true;
        # overlay-scrolling = true;
        show-battery-percentage = true;
      };
      "org/gnome/desktop/calendar" = {
        show-weekdate = true;
      };
      "org/gnome/desktop/datetime" = {
        # We use systemd automatic timezone
        # Enabling this is harmless too, but
        # results in notification of change
        # each time in a different timezone for laptops,
        # since we have default TZ set.
        automatic-timezone = true;
      };
      "org/gnome/system/location" = {
        enabled = true;
      };
      # "org/gnome/Console" = {
      #  shell = [ "tmux" ];
      # };
    };
  };
}
