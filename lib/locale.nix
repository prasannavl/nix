{
  lib,
  ...
}: {
  # We automatically set this below.
  # Issue: https://github.com/NixOS/nixpkgs/issues/68489
  # 
  # time.timeZone = "Asia/Singapore";

  i18n.defaultLocale = "en_US.UTF-8";

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

  # This doesn't always work however. So 
  # we use tzupdate as fallback.
  services.automatic-timezoned.enable = true;
  services.geoclue2.geoProviderUrl = "https://api.beacondb.net/v1/geolocate";

  # Automatic timezones based on geo ip.
  # Not as accurate as automatic-timezoned above
  # but reliable fallback.
  # tzlogic: https://github.com/cdown/tzupdate/blob/437b3f0cef1ac85a97f8ba3dab97bd7090deb2bb/src/http.rs#L15-L44
  services.tzupdate.enable = true;
}
