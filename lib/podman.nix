{lib, ...}: {
  virtualisation.containers = {
    enable = true;
    containersConf.settings.engine.compose_warning_logs = lib.mkDefault false;
  };

  virtualisation.podman = {
    enable = lib.mkDefault true;
    dockerCompat = lib.mkDefault true;
    defaultNetwork.settings.dns_enabled = lib.mkDefault true;
  };
}
