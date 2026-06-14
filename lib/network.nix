{hostName, ...}: {
  imports = [
    ./openssh.nix
    ./services/fail2ban-helper
  ];

  networking = {
    hostName = hostName;
    networkmanager.enable = true;
    nftables.enable = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [];
      allowedUDPPorts = [];
    };
  };

  services = {
    resolved.enable = true;
    tailscale = {
      enable = true;
      useRoutingFeatures = "client";
    };
  };
}
