{...}: {
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
  };
  boot.tmp.useTmpfs = true;
}
