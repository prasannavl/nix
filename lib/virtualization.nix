{
  config,
  pkgs,
  ...
}: {
  systemd.targets.machines.enable = true;

  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };
}
