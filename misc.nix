{ config, pkgs, ... }:
{
  virtualisation.containers.enable = true;
  virtualisation.podman.enable = true;
  virtualisation.incus.enable = true;
}
