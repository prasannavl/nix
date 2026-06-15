{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  systemdLessThan260 = version: lib.versionOlder version "260";
in {
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    nssmdns6 = true;
  };

  # Choose one mDNS stack.
  services.resolved = let
    resolvedSettings = {
      settings.Resolve = lib.mkIf config.services.resolved.enable {
        MulticastDNS = "no";
      };
    };
    resolvedExtraConfig = {
      extraConfig = lib.optionalString config.services.resolved.enable ''
        MulticastDNS=no
      '';
    };
  in
    if systemdLessThan260 pkgs.systemd.version || !(options.services.resolved ? settings)
    then resolvedExtraConfig
    else resolvedSettings;
}
