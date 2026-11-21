{...}: {
  hardware = {
    enableAllFirmware = true;
    i2c.enable = true;
    bluetooth.enable = true;
  };
  services = {
    fwupd.enable = true;
    power-profiles-daemon.enable = true;
    upower.enable = true;
  };
}
