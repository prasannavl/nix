{...}: {
  networking.firewall = {
    trustedInterfaces = ["incusbr0"];
  };
  # Internal network only
  # All ports except https are locked down on the network
  # firewall and only accessible through the tailscale interface.
  networking.firewall.allowedTCPPorts = [
    # memos
    5230
    # docmost
    3000
    # immich
    2283
    # incus
    8443
    # opencloud
    9200
    9300
    9980
    # beszel
    9080
    # vaultwarden
    2000
    # portainer
    8001
    # shadowsocks
    8388
  ];
  networking.firewall.allowedUDPPorts = [
    # shadowsocks
    8388
  ];
}
