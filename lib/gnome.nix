{
  config,
  pkgs,
  ...
}: {
  security.rtkit.enable = true;
  security.polkit.enable = true;
  security.pam.services.login.enableGnomeKeyring = true;

  services.desktopManager.gnome.enable = true;
  services.desktopManager.gnome.extraGSettingsOverrides = ''
    [org.gnome.mutter]
    experimental-features=['scale-monitor-framebuffer', 'variable-refresh-rate', 'xwayland-native-scaling']
  '';
  services.gnome.core-apps.enable = true;

  services.gnome.gnome-keyring.enable = true;
  services.gnome.gcr-ssh-agent.enable = true;
  # Disable other known agents if using gcr-ssh-agent.
  programs.gnupg.agent.enableSSHSupport = false;
  programs.ssh.startAgent = false;

  # services.gnome.gnome-online-accounts.enable = true;
  services.gvfs.enable = true;
  services.udev.packages = [pkgs.gnome-settings-daemon];

  # Gnome using wsdd for Windows network discovery
  services.samba-wsdd.enable = true;
  services.samba-wsdd.openFirewall = true;

  # programs.dconf.profiles.user.databases = [];

  xdg.portal = {
    enable = true;
    extraPortals = [pkgs.xdg-desktop-portal-gnome];
    config.common.default = "gnome";
  };
}
