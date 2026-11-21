{overridePathForHost ? _hostName: null}: {
  hostName ? null,
  inputs,
  lib,
  ...
}: let
  installerOverrides =
    if hostName == null
    then null
    else overridePathForHost hostName;
in {
  imports =
    [
      inputs.disko.nixosModules.disko
    ]
    ++ lib.optional (
      installerOverrides != null && builtins.pathExists installerOverrides
    )
    installerOverrides;
}
