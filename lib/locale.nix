{
  config,
  lib,
  pkgs,
  ...
}: {
  # We automatically set this below.
  # But we set it anyway due to:
  # https://github.com/nixos/nixpkgs/issues/499098
  # https://issues.chromium.org/issues/40069710
  # Bug affects Chrome, Electron, etc
  time.timeZone = "Asia/Singapore";
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

  # Note: Issue: https://github.com/NixOS/nixpkgs/issues/68489

  # Disabled as it's exclusive to setting manually above that
  # we do for bugfix.
  # services.automatic-timezoned.enable = true;

  services.geoclue2 = {
    # see: https://github.com/NixOS/nixpkgs/issues/68489#issuecomment-1484030107
    enableDemoAgent = lib.mkForce true;
    geoProviderUrl = "https://beacondb.net/v1/geolocate";
  };

  # Automatic timezones based on geo ip.
  # Not as accurate as automatic-timezoned above
  # but reliable fallback if needed.
  # tzlogic: https://github.com/cdown/tzupdate/blob/437b3f0cef1ac85a97f8ba3dab97bd7090deb2bb/src/http.rs#L15-L44
  # services.tzupdate.enable = true;

  # Refresh on network events: geoclue queries lazily, so restart the daemon
  # to force one. Inert without automatic-timezoned. See
  # .agents/docs/notes/hosts/timezone-follows-wan-2026-11.md
  # getExe: dispatcher hook needs a file; writeShellApplication is a dir.
  networking.networkmanager.dispatcherScripts = lib.optional config.services.automatic-timezoned.enable {
    type = "basic";
    source = lib.getExe (pkgs.writeShellApplication {
      name = "automatic-timezoned-refresh";
      runtimeInputs = [config.systemd.package];
      text = ''
        # args: iface, action, ...
        [ "''${2-}" = connectivity-change ] || exit 0
        exec systemctl --no-block try-restart automatic-timezoned.service
      '';
    });
  };

  powerManagement.resumeCommands = lib.optionalString config.services.automatic-timezoned.enable ''
    ${config.systemd.package}/bin/systemctl --no-block try-restart automatic-timezoned.service
  '';
}
