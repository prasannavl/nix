{
  config,
  pkgs,
  ...
}: {
  # Hostname is set per-host under hosts/*/default.nix
  networking.networkmanager.enable = true;
  networking.nftables.enable = true;

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [];
  networking.firewall.allowedUDPPorts = [];
}
