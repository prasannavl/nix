{lib, ...}: {
  networking.firewall = {
    trustedInterfaces = ["incusbr0"];
  };

  # networking.firewall.enable = lib.mkForce false;

  # networking.firewall.allowedTCPPortRanges = [
  #   { from = 32768; to = 60999; }
  # ];

  # networking.nat = {
  #   enable = true;
  #   externalInterface = "wlan0";
  #   # Container virtual interfaces
  #   internalInterfaces = ["ve-+"];
  #   # Lazy IPv6 connectivity for containers
  #   enableIPv6 = true;
  # };
}
