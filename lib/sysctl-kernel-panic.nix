{...}: {
  boot.kernel.sysctl = {
    # panic
    "kernel.panic_on_oops" = 0;
    "kernel.panic" = 60;

    "kernel.hung_task_timeout_secs" = 120;
    "kernel.hung_task_panic" = 0;

    "kernel.softlockup_panic" = 0;
    "kernel.hardlockup_panic" = 0;

    "kernel.watchdog" = 1;
    "kernel.watchdog_thresh" = 30;
  };
}
