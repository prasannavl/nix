_: {
  networking.firewall = {
    logRefusedConnections = false;
    trustedInterfaces = ["incusbr0"];
  };

  # Internal network only
  # All ports except https are locked down on the network
  # firewall and only accessible through the tailscale interface.
  networking.firewall.allowedTCPPorts = [
    # incus
    8443
    # opencloud
    9200
    9300
    9980
    # https
    443
  ];
}
