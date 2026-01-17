{
  config,
  pkgs,
  ...
}: {
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    nssmdns6 = true;
  };

  services.resolved = {
    enable = true;
    # Choose one mDNS stack, avahi is nicer.
    extraConfig = ''
      MulticastDNS=no
    '';
  };

  services.automatic-timezoned.enable = true;
  services.geoclue2.geoProviderUrl = "https://api.beacondb.net/v1/geolocate";

  services.seatd.enable = true;
  services.openssh.enable = true;
  services.tailscale.enable = true;

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  services.xserver.enable = true;
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  services.fail2ban.enable = true;
}
