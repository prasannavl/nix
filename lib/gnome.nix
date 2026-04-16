{pkgs, ...}: {
  security = {
    rtkit.enable = true;
    polkit.enable = true;
    pam.services.login.enableGnomeKeyring = true;
  };

  services = {
    desktopManager.gnome = {
      enable = true;
      extraGSettingsOverrides = ''
        [org.gnome.mutter]
        experimental-features=['scale-monitor-framebuffer', 'variable-refresh-rate', 'xwayland-native-scaling']
      '';
    };
    gnome = {
      core-apps.enable = true;
      gnome-keyring.enable = true;
      gcr-ssh-agent.enable = true;
    };
    gvfs.enable = true;
    udev.packages = [pkgs.gnome-settings-daemon];
    # Gnome using wsdd for Windows network discovery
    samba-wsdd = {
      enable = true;
      openFirewall = true;
    };
    sysprof.enable = true;
  };

  # Disable other known agents if using gcr-ssh-agent.
  programs.gnupg.agent.enableSSHSupport = false;
  programs.ssh.startAgent = false;

  # services.gnome.gnome-online-accounts.enable = true;
  # programs.dconf.profiles.user.databases = [];

  xdg.portal = {
    enable = true;
    extraPortals = [pkgs.xdg-desktop-portal-gnome];
    config.common.default = "gnome";
  };

  environment.systemPackages = with pkgs; [
    gnome-screenshot
    gnome-sound-recorder
    remmina
  ];
}
