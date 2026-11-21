{...}: {
  systemd = {
    tmpfiles.rules = [
      "d /var/lib 0755 root root -"
    ];

    network = {
      enable = true;
      wait-online.extraArgs = [
        "--interface=eth0:routable"
      ];
      networks."10-eth0" = {
        matchConfig.Name = "eth0";
        DHCP = "yes";
        dhcpV4Config.UseHostname = false;
        dhcpV6Config.UseHostname = false;
        networkConfig.IPv6AcceptRA = true;
      };
    };
  };

  networking = {
    useNetworkd = true;
    useHostResolvConf = false;
    networkmanager.enable = false;
    useDHCP = false;
  };

  services.resolved.enable = true;
}
