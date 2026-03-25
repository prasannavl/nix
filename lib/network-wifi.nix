{pkgs, ...}: {
  # Enables wireless support via wpa_supplicant.
  # We use nm instead.
  # networking.wireless.enable = true;

  networking.networkmanager.wifi = {
    backend = "iwd";
    # Disable WiFi power saving (causes disconnections)
    powersave = false;
    # Consistent MAC during scans (randomization causes issues)
    scanRandMacAddress = false;
  };

  # iwd configuration for MT7925 stability
  networking.wireless.iwd.settings = {
    General = {
      # Consistent MAC per network (fixes WPA3 handshake issues)
      AddressRandomization = "disabled"; # disabled/network/once
      # Let NetworkManager handle IP configuration, not iwd
      # (prevents conflicts between iwd and NetworkManager)
      # AddressRandomizationRange = "nic" # nic / full;
      EnableNetworkConfiguration = false;
    };
    Settings = {
      AutoConnect = true;
    };
  };

  # Restart after resume to clear stale driver state for buggy firmware.
  powerManagement.resumeCommands = ''
    ${pkgs.systemd}/bin/systemctl restart NetworkManager.service
  '';
}
