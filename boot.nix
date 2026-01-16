{
  config,
  pkgs,
  ...
}: {
  boot.loader = {
    timeout = 3;
    systemd-boot = {
      enable = true;
      configurationLimit = 10;
    };
    efi.canTouchEfiVariables = true;
  };
  boot.initrd.systemd = {
    enable = true;
    tpm2.enable = true;
  };
  boot.kernelParams = [
    "quiet"
    "fbcon=map:0"
    # "ramoops.mem_size=0x100000"
    # "ramoops.record_size=0x10000"
    # "ramoops.console_size=0x8000"
    "vt.global_cursor_default=0"
    # "video=HDMI-A-1:1920x1080@60e"
  ];
  boot.kernel.sysctl = {
    "kernel.sysrq" = 1;

    # panic
    "kernel.panic_on_oops" = 0;
    "kernel.panic" = 60;

    "kernel.hung_task_timeout_secs" = 120;
    "kernel.hung_task_panic" = 0;

    "kernel.softlockup_panic" = 0;
    "kernel.hardlockup_panic" = 0;

    "kernel.watchdog" = 1;
    "kernel.watchdog_thresh" = 30;

    # swappiness
    "vm.swappiness" = 5;

    # core dumps
    "kernel.core_uses_pid" = 1;

    # inotify
    "fs.inotify.max_queued_events" = 16384;
    "fs.inotify.max_user_instances" = 4096;
    "fs.inotify.max_user_watches" = 1048576;
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;
}
