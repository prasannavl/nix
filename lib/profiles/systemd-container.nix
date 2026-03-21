{
  pkgs,
  modulesPath,
  hostName,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/lxc-container.nix")
    (modulesPath + "/virtualisation/lxc-image-metadata.nix")
    ../openssh.nix
    ../options.nix
    ../nix.nix
    ../systemd.nix
    ../security.nix
    ../sudo.nix
    ../nixbot
    ../nix-ld.nix
    ../users.nix
  ];

  # This host is designed to run as a container image (shared kernel).
  boot.isContainer = true;

  # Image-specific trim for container builds.
  documentation.enable = false;
  boot.enableContainers = false;
  networking = {
    inherit hostName;
    useNetworkd = true;
    useHostResolvConf = false;
    networkmanager.enable = false;
    useDHCP = false;
    firewall = {
      enable = true;
      allowedTCPPorts = [];
      allowedUDPPorts = [];
    };
    nftables.enable = true;
  };
  time.timeZone = "Asia/Singapore";
  i18n.defaultLocale = "en_US.UTF-8";

  programs = {
    bash = {
      enable = true;
      completion.enable = true;
    };
    htop.enable = true;
    mtr.enable = true;
    git.enable = true;
    tmux.enable = true;
  };
  systemd.network.enable = true;

  systemd.network.networks."10-eth0" = {
    matchConfig.Name = "eth0";
    DHCP = "yes";
    networkConfig.IPv6AcceptRA = true;
  };

  services = {
    getty.autologinUser = null;
    resolved.enable = true;
    tailscale.enable = true;
    fail2ban.enable = true;
  };

  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "hello";
      text = "echo hello world!";
    })
  ];
}
