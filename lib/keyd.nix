{...}: {
  services.keyd = {
    enable = true;
  };

  users.groups.keyd = {};

  systemd.services.keyd.serviceConfig = {
    CapabilityBoundingSet = ["CAP_SETGID"];
    AmbientCapabilities = ["CAP_SETGID"];
  };
}
