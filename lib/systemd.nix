{config, ...}: {
  config = {
    systemd = {
      settings.Manager = {
        # Notify pre-timeout
        RuntimeWatchdogPreSec = "60s";
        # Reboot if PID 1 hangs (set to "off" to disable)
        RuntimeWatchdogSec =
          if config.x.panicReboot == 1
          then "5min"
          else "off";
        # HW watchdog reset limit during shutdown/reboot
        RebootWatchdogSec = "5min";
        DefaultLimitNOFILE = toString config.x.fdlimit;
      };

      # user conf
      user.extraConfig = ''
        DefaultLimitNOFILE=${toString config.x.fdlimit}
      '';

      # Misc systemd
      targets.machines.enable = true;
    };

    services.logind.settings.Login = {
      HandleLidSwitch = "suspend";
      HandleLidSwitchExternalPower = "ignore";
      HandleLidSwitchDocked = "ignore";
    };
  };
}
