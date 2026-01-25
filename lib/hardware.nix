{ lib, ...}: {
  # Enable all firmware
  hardware.enableAllFirmware = true;
  hardware.i2c.enable = true;
  hardware.bluetooth.enable = true;

  # Other hardware related services
  services.fwupd.enable = true;
  services.power-profiles-daemon.enable = true;
  services.upower.enable = true;

  # For SSDs
  services.fstrim.enable = true;
}
