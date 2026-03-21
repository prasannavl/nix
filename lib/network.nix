{hostName, ...}: {
  imports = [
    ./openssh.nix
  ];

  networking = {
    inherit hostName;
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
    tailscale.enable = true;
    fail2ban.enable = true;
  };
}
