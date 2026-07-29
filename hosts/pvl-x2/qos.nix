{
  config,
  lib,
  ...
}: let
  incusBridgeInterfaces =
    map (network: network.name)
    (lib.filter
      (network: (network.type or null) == "bridge")
      config.virtualisation.incus.preseed.networks);
in {
  imports = [../../lib/services/host-network-qos];

  services.host-network-qos = {
    enable = true;
    interface = "eno1";
    uploadBandwidth = "900Mbit";
    downloadBandwidth = "900Mbit";
    bulkInterfaces = incusBridgeInterfaces;
  };
}
