{hostName, ...}: {
  networking.hostName = hostName;

  networking.networkmanager.enable = true;
  networking.nftables.enable = true;

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [];
  networking.firewall.allowedUDPPorts = [];

  services.resolved = {
    enable = true;
  };

  services.openssh.enable = true;
  services.tailscale.enable = true;
  services.fail2ban.enable = true;
}
