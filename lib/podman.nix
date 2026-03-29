{lib, ...}: {
  virtualisation.containers.enable = true;

  virtualisation.podman = {
    enable = lib.mkDefault true;
    dockerCompat = lib.mkDefault true;
    defaultNetwork.settings.dns_enabled = lib.mkDefault true;
  };

  virtualisation.containers.containersConf.settings.engine.compose_warning_logs = lib.mkDefault false;
}
