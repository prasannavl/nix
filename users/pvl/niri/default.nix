{
  nixos = {pkgs, ...}: {
    environment.systemPackages = with pkgs; [
      niri
      xdg-desktop-portal-gnome
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

  home = {pkgs, ...}: {
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
  };
}
