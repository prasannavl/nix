{config, lib, pkgs, ...}: {
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

  systemd.services = let
    gnomeRdpEnv = [
      "PATH=${config.security.wrapperDir}/bin:${config.system.path}/bin"
      "SHELL=${pkgs.bash}"
      "XDG_DATA_DIRS=${config.system.path}/share"
    ];
  in {
    gnome-remote-desktop = {
      wantedBy = ["display-manager.service"];
      after = ["display-manager.service"];
      serviceConfig = {
        Environment = gnomeRdpEnv;
      };
    };

    gnome-remote-desktop-configuration = {
      serviceConfig = {
        Environment = gnomeRdpEnv;
      };
    };
  };

  users.users.gnome-remote-desktop.extraGroups =
    lib.optionals config.security.tpm2.enable ["tss"];
}
