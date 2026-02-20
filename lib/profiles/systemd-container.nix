{
  pkgs,
  modulesPath,
  hostName,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/lxc-container.nix")
    (modulesPath + "/virtualisation/lxc-image-metadata.nix")
    ../options.nix
    ../nix.nix
    ../systemd.nix
    ../security.nix
    ../sudo.nix
    ../nixbot.nix
    ../nix-ld.nix
    ../users.nix
  ];

  # This host is designed to run as a container image (shared kernel).
  boot.isContainer = true;

  # Image-specific trim for container builds.
  documentation.enable = false;
  boot.enableContainers = false;
  services.getty.autologinUser = null;

  networking.hostName = hostName;
  time.timeZone = "Asia/Singapore";
  i18n.defaultLocale = "en_US.UTF-8";

  programs.bash = {
    enable = true;
    completion.enable = true;
  };
  programs.htop.enable = true;
  programs.mtr.enable = true;
  programs.git.enable = true;
  programs.tmux.enable = true;

  networking.useNetworkd = true;
  systemd.network.enable = true;
  networking.useHostResolvConf = false;
  networking.networkmanager.enable = false;
  networking.useDHCP = false;

  systemd.network.networks."10-eth0" = {
    matchConfig.Name = "eth0";
    DHCP = "yes";
    networkConfig.IPv6AcceptRA = true;
  };

  networking.firewall.enable = true;
  networking.nftables.enable = true;
  networking.firewall.allowedTCPPorts = [];
  networking.firewall.allowedUDPPorts = [];

  services.resolved = {
    enable = true;
  };

  services.openssh.enable = true;
  services.tailscale.enable = true;
  services.fail2ban.enable = true;

  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "hello";
      text = "echo hello world!";
    })
  ];
}
