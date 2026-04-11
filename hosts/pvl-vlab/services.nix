{config, ...}: let
  videoGid = toString config.users.groups.video.gid;
  renderGid = toString config.users.groups.render.gid;
in {
  systemd.tmpfiles.rules = [
    "d /var/lib/pvl 0755 pvl pvl -"
  ];
  
  networking.firewall.allowedTCPPorts = [];

  services.podmanCompose.pvl = {
    user = "pvl";
    stackDir = "/var/lib/pvl/compose";
    servicePrefix = "pvl-";
  };
}
