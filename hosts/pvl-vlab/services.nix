{...}: {
  systemd.tmpfiles.rules = [
    "d /var/lib/pvl 0755 pvl pvl -"
  ];

  services.podmanCompose.pvl = {
    user = "pvl";
    stackDir = "/var/lib/pvl/compose";
    servicePrefix = "pvl-";
  };
}
