{...}: {
  boot = {
    loader = {
      timeout = 3;
      systemd-boot = {
        enable = true;
        configurationLimit = 10;
        consoleMode = "max";
      };
      efi.canTouchEfiVariables = true;
    };

    initrd.systemd.enable = true;

    # rtc_cmos=m: loaded late it re-applies a reset RTC over the time PID 1
    # restored from the timesync clock file. In initrd the RTC read lands first.
    initrd.availableKernelModules = ["rtc_cmos"];
    tmp.useTmpfs = true;
  };
}
