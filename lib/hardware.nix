{...}: {
  # Enable all firmware
  hardware = {
    enableAllFirmware = true;
    i2c.enable = true;
    bluetooth.enable = true;
  };

  # Other hardware related services
  services = {
    fwupd.enable = true;
    power-profiles-daemon.enable = true;
    upower.enable = true;

    # For SSDs
    fstrim.enable = true;
  };
}
