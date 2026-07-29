{...}: {
  imports = [../../lib/services/host-network-qos];

  services.host-network-qos = {
    enable = true;
    interface = "eno1";
    uploadBandwidth = "900Mbit";
    downloadBandwidth = "900Mbit";
    bulkInterfaces = [
      "incusbr0"
      "ipvlbr0"
      "iabirdplatbr0"
      "iabirdbr0"
      "iabirdbr2"
    ];
  };
}
