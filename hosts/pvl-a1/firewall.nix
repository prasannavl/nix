{...}: {
  networking.firewall = {
    trustedInterfaces = ["incusbr0"];
  };

  # networking.nat = {
  #   enable = true;
  #   externalInterface = "wlan0";
  #   # Container virtual interfaces
  #   internalInterfaces = ["ve-+"];
  #   # Lazy IPv6 connectivity for containers
  #   enableIPv6 = true;
  # };
}
