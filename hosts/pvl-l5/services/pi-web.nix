{config, ...}: {
  imports = [../../../lib/services/pi-web];

  services.pi-web = {
    enable = true;
    tailnetAccess = true;
    allowedHosts = [
      config.networking.hostName
      "${config.networking.hostName}.tailcaaad.ts.net"
    ];
  };
}
