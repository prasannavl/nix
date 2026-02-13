{...}: {
  boot.loader = {
    timeout = 3;
    systemd-boot = {
      enable = true;
      configurationLimit = 10;
      consoleMode = "max";
    };
    efi.canTouchEfiVariables = true;
  };
  boot.initrd.systemd = {
    enable = true;
  };
  boot.tmp.useTmpfs = true;
}
