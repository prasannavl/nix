{
  config,
  pkgs,
  ...
}: {
  networking.hostName = "pvl-a1";
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  networking.networkmanager.enable = true;
  networking.nftables.enable = true;

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [];
  networking.firewall.allowedUDPPorts = [];

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

  # Restart after suspend to clear stale driver state for buggy firmware
  systemd.services.networkmanager-restart-on-suspend = {
    description = "Restart NetworkManager after suspend for buggy network cards like MediaTek, etc";
    wantedBy = [
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
    ];
    after = [
      "suspend.target"
      "hibernate.target"
      "hybrid-sleep.target"
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${pkgs.systemd}/bin/systemctl restart NetworkManager.service";
    };
  };
}
