{
  ab,
  config,
  pkgs,
  ...
}: {
  imports = [
    (ab.services.piWeb.nixos {
      defaultPackage = pkgs.callPackage ../../../nix/ext/pi/pi-web {};
      defaultUser = "pvl";
    })
  ];

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
