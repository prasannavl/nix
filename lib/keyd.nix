{config, lib, ...}: let
  cfg = config.services.keyd;
in {
  config = lib.mkIf cfg.enable {
    users.groups.keyd = {};

    systemd.services.keyd.serviceConfig = {
      CapabilityBoundingSet = ["CAP_SETGID"];
      AmbientCapabilities = ["CAP_SETGID"];
    };
  };
}
