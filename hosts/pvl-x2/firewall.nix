{...}: {
  # Internal network only
  # All ports except https are locked down on the network
  # firewall and only accessible through the tailscale interface.
  networking.firewall.allowedTCPPorts = [3000 2283];
  networking.firewall.allowedUDPPorts = [];
}
