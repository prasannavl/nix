{config, ...}: {
  imports = [../../../ab/services/pi-web/nixos.nix];

  services.pi-web = {
    enable = true;
    mcp.enable = false;
    tailnetAccess = true;
    allowedHosts = [
      config.networking.hostName
      "${config.networking.hostName}.tailcaaad.ts.net"
    ];
  };
}
