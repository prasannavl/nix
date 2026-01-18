{config, lib, ...}: {
  
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    nssmdns6 = true;
  };

  services.resolved = {
    # Choose one mDNS stack
    extraConfig = lib.optionalString config.services.resolved.enable ''
      MulticastDNS=no
    '';
  };
}
