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
    tmp.useTmpfs = true;
  };
}
