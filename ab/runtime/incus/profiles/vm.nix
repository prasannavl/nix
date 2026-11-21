{
  lib,
  modulesPath,
  ...
}: {
  imports = [
    ./guest.nix
    (modulesPath + "/virtualisation/incus-virtual-machine.nix")
  ];

  virtualisation.incus.agent.enable = lib.mkDefault true;
}
