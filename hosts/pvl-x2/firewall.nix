{...}: {
  networking.firewall = {
    logRefusedConnections = false;
  };

  # Internal network only
  # All ports except https are locked down on the network
  # firewall and only accessible through the tailscale interface.
  networking.firewall = {
    allowedUDPPorts = [];
    allowedTCPPorts = [
      # incus
      8443
      # https
      443
    ];
  };
}
