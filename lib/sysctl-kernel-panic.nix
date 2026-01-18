{lib, config, ...}: {
  options.x.panicReboot = lib.mkOption {
    type = lib.types.enum [0 1];
    default = 1;
    description = "Enable or disable panic recovery sysctl settings.";
  };

  config = {
    boot.kernel.sysctl = let
      reboot = config.x.panicReboot == 1;
    in {
      # panic
      "kernel.panic_on_oops" = if reboot then 1 else 0;
      "kernel.panic" = 60;

      "kernel.hung_task_timeout_secs" = 120;
      "kernel.hung_task_panic" = 0;

      "kernel.softlockup_panic" = if reboot then 1 else 0;
      "kernel.hardlockup_panic" = if reboot then 1 else 0;

      "kernel.watchdog" = 1;
      "kernel.watchdog_thresh" = 30;
    };
  };
}
