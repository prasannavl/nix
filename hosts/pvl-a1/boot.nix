{
  config,
  pkgs,
  ...
}: {
  imports = [
    ../../lib/sysctl-kernel-coredump.nix
    ../../lib/sysctl-inotify.nix
    ../../lib/sysctl-kernel-panic.nix
    ../../lib/sysctl-kernel-sysrq.nix
  ];

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
    "vt.global_cursor_default=0"
    # "video=HDMI-A-1:1920x1080@60e"
  ];
  boot.kernel.sysctl = {
    # swappiness
    "vm.swappiness" = 5;

  };

  boot.kernelPackages = pkgs.linuxPackages_latest;
}
