{
  hostName,
  lib,
  ...
}: {
  imports = [
    ./openssh.nix
    ./services/fail2ban-helper
  ];

  networking = {
    hostName = hostName;
    networkmanager.enable = true;
    nftables.enable = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [];
      allowedUDPPorts = [];
    };
  };

  services = {
    resolved = {
      enable = true;
      # Tailscale owns its link-scoped DNS routes and explicitly disables these
      # global policies on tailscale0, preserving MagicDNS and split DNS.
      settings.Resolve = {
        DNS = lib.mkDefault [
          "1.1.1.1#one.one.one.one"
          "1.0.0.1#one.one.one.one"
          "2606:4700:4700::1111#one.one.one.one"
          "2606:4700:4700::1001#one.one.one.one"
        ];
        FallbackDNS = lib.mkDefault [];
        Domains = lib.mkDefault ["~."];
        DNSOverTLS = lib.mkDefault true;
        DNSSEC = lib.mkDefault true;
      };
    };
    tailscale = {
      enable = true;
      useRoutingFeatures = lib.mkDefault "client";
    };
  };
}
