{...}: {
  networking.firewall = {
    trustedInterfaces = ["p2p-*"];
    extraInputRules = ''
      iifname "wlan0" ip saddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } tcp dport 32768-60999 accept comment "Dynamic user ports on private LANs for Casts, Network Displays, etc"
    '';
  };

  # Common debug config
  # networking.firewall.enable = lib.mkForce false;
  # networking.firewall.allowedUDPPortRanges = [ { from = 1024; to = 65535; } ];
  # networking.firewall.allowedTCPPortRanges = [
  #   { from = 32768; to = 60999; }
  # ];
  # networking.firewall.allowedTCPPorts = [];
  # networking.firewall.allowedUDPPorts = [];

  # networking.nat = {
  #   enable = true;
  #   externalInterface = "wlan0";
  #   # Container virtual interfaces
  #   internalInterfaces = ["ve-+"];
  #   # Lazy IPv6 connectivity for containers
  #   enableIPv6 = true;
  # };
}
