{
  lib,
  ...
}: {
  # We leave it override-able.
  time.timeZone = lib.mkDefault "Asia/Singapore";
  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";

  # i18n.extraLocaleSettings = {
  #   LC_ADDRESS = locale;
  #   LC_IDENTIFICATION = locale;
  #   LC_MEASUREMENT = locale;
  #   LC_MONETARY = locale;
  #   LC_NAME = locale;
  #   LC_NUMERIC = locale;
  #   LC_PAPER = locale;
  #   LC_TELEPHONE = locale;
  #   LC_TIME = locale;
  # };

  services.automatic-timezoned.enable = true;
  services.geoclue2.geoProviderUrl = "https://api.beacondb.net/v1/geolocate";
}
