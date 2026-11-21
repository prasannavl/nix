{
  config,
  lib,
  ...
}: {
  config = lib.mkIf config.services.keyd.enable {
    users.groups.keyd = {};

    systemd.services.keyd.serviceConfig = {
      CapabilityBoundingSet = ["CAP_SETGID"];
      AmbientCapabilities = ["CAP_SETGID"];
    };
  };
}
