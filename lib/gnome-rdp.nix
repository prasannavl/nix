{
  config,
  ...
}: {
  services.gnome.gnome-remote-desktop.enable = true;

  programs.dconf.profiles.gdm.databases = [
    {
      settings = {
        "org/gnome/desktop/remote-desktop/rdp" = {
          enable = true;
          view-only = false;
        };
      };
    }
  ];

  systemd.services.gnome-remote-desktop = {
    wantedBy = ["display-manager.service"];
    after = ["display-manager.service"];
    serviceConfig = {
      Environment = [
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
        "SHELL=/run/current-system/sw/bin/bash"
        "XDG_DATA_DIRS=/run/current-system/sw/share"
      ];
    };
  };

  systemd.services.gnome-remote-desktop-configuration = {
    serviceConfig = {
      Environment = [
        "PATH=/run/wrappers/bin:/run/current-system/sw/bin"
        "SHELL=/run/current-system/sw/bin/bash"
        "XDG_DATA_DIRS=/run/current-system/sw/share"
      ];
    };
  };

  users.users.gnome-remote-desktop.extraGroups = ["tss"];
}
