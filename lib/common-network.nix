{...}: {
  networking.networkmanager.enable = true;
  networking.nftables.enable = true;

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [];
  networking.firewall.allowedUDPPorts = [];
}
