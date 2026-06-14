{
  hostName ? null,
  inputs,
  lib,
  ...
}: let
  # offline-install writes this into the installed repo with the effective disk
  # path, partition UUIDs, and LUKS UUID used for that machine.
  installerOverrides =
    if hostName == null
    then null
    else ../../hosts + "/${hostName}/installer-overrides.nix";
in {
  imports =
    [
      inputs.disko.nixosModules.disko
    ]
    ++ lib.optional (installerOverrides != null && builtins.pathExists installerOverrides) installerOverrides;
}
