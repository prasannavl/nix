{...}: {
  networking.firewall = {
    trustedInterfaces = ["incusbr0"];
  };

  # Common debug config
  # networking.firewall.enable = lib.mkForce false;
  # networking.firewall.allowedUDPPortRanges = [ { from = 1024; to = 65535; } ];
  # networking.firewall.allowedTCPPortRanges = [
  #   { from = 32768; to = 60999; }
  # ];

  networking.firewall.allowedTCPPorts = [ 7236 7250 ];
  networking.firewall.allowedUDPPorts = [ 7236 5353 ];

  # networking.nat = {
  #   enable = true;
  #   externalInterface = "wlan0";
  #   # Container virtual interfaces
  #   internalInterfaces = ["ve-+"];
  #   # Lazy IPv6 connectivity for containers
  #   enableIPv6 = true;
  # };
}
