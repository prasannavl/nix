{
  config,
  pkgs,
  lib,
  ...
}: let
  tzUTC = "UTC";
  tzSG = "Asia/Singapore";
  tzIN = "Asia/Kolkata";
  tzUS_NY = "America/New_York";
  localeUS = "en_US.UTF-8";
  localeSG = "en_SG.UTF-8";
  localeIN = "en_IN.UTF-8";
  
  tz = tzSG;
  locale = localeUS;
in {
  time.timeZone = lib.mkDefault tz;

  i18n.defaultLocale = locale;
  i18n.extraLocaleSettings = {
    LC_ADDRESS = locale;
    LC_IDENTIFICATION = locale;
    LC_MEASUREMENT = locale;
    LC_MONETARY = locale;
    LC_NAME = locale;
    LC_NUMERIC = locale;
    LC_PAPER = locale;
    LC_TELEPHONE = locale;
    LC_TIME = locale;
  };
}
