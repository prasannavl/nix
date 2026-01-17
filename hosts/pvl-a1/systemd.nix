{
  config,
  pkgs,
  ...
}: {
  systemd.settings.Manager = {
    # Notify pre-timeout
    RuntimeWatchdogPreSec = "60s";
    # Reboot if PID 1 hangs (set to "off" to disable)
    RuntimeWatchdogSec = "off";
    # HW watchdog reset limit during shutdown/reboot
    RebootWatchdogSec = "5min";
    DefaultLimitNOFILE = "1048576";
  };

  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };

  # user conf
  systemd.user.extraConfig = ''
    DefaultLimitNOFILE=1048576
  '';

  systemd.services.keyd.serviceConfig = {
    CapabilityBoundingSet = ["CAP_SETGID"];
    AmbientCapabilities = ["CAP_SETGID"];
  };
}
