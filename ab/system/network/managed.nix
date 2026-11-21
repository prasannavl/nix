{
  hostName,
  lib,
  config,
  ...
}: let
  # Never restart the deploy transport (Wi-Fi -> Tailscale -> SSH) mid-switch.
  holdAcrossSwitch = {
    restartIfChanged = lib.mkForce false;
    reloadIfChanged = lib.mkForce false;
  };
in {
  imports = [
    ../security/openssh.nix
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
    resolved.enable = true;
    tailscale = {
      enable = true;
      useRoutingFeatures = lib.mkDefault "client";
    };
  };

  systemd.services =
    {
      NetworkManager = holdAcrossSwitch;
      tailscaled = holdAcrossSwitch;
    }
    // lib.optionalAttrs config.networking.wireless.iwd.enable {
      iwd = holdAcrossSwitch;
    };
}
