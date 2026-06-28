{
  config,
  lib,
  ...
}: {
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    nssmdns6 = true;
  };

  # Choose one mDNS stack.
  services.resolved = {
    settings.Resolve = lib.mkIf config.services.resolved.enable {
      MulticastDNS = "no";
    };
  };
}
