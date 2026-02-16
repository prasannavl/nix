{...}: {
  # Keep network policy at the podman host boundary by default.
  networking.firewall.enable = false;
  networking.firewall.allowedTCPPorts = [ 22 ];
}
