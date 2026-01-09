{...}: {
  dconfSettings = {
    "org/gnome/shell/keybindings" = {
      screenshot = ["<Shift>Print" "<Shift><Super>c"];
      screenshot-window = ["<Alt>Print" "<Alt><Super>c"];
      show-screenshot-ui = ["Print" "<Super>c"];
    };

    "org/gnome/settings-daemon/plugins/media-keys" = {
      help = [];
      custom-keybindings = [
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1/"
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom2/"
      ];
    };

    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
      binding = "<Super>Return";
      command = "kgx";
      name = "Terminal";
    };

    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom1" = {
      binding = "<Alt><Super>g";
      command = "sudo /home/pvl/bin/amdgpu-reset.sh";
      name = "Reset amdgpu";
    };

    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom2" = {
      binding = "<Alt><Super>r";
      command = "/home/pvl/bin/mutter-reset-displays.sh";
      name = "Reset displays - mutter";
    };

    "org/gnome/desktop/wm/keybindings" = {
      show-desktop = ["<Super>d"];
      maximize-vertically = ["<Super>z"];
      begin-move = ["<Shift><Super>m"];
      begin-resize = ["<Shift><Super>r"];
      toggle-fullscreen = ["<Shift><Super>f"];
      toggle-maximized = ["<Super>f"];
      switch-windows = ["<Alt>Tab"];
      switch-windows-backward = ["<Shift><Alt>Tab"];
      switch-applications = ["<Super>Tab"];
      switch-applications-backward = ["<Shift><Super>Tab"];
    };
  };
}
