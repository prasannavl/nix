{ config, pkgs, ... }:
{
  hardware.i2c.enable = true;
  
  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
  };
  virtualisation.incus.enable = true;
}
