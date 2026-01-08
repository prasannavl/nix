{ config, pkgs, ... }:
{
  hardware.i2c.enable = true;
  
  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };
  virtualisation.incus.enable = true;

  security.unprivilegedUsernsClone = true;
}
