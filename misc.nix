{
  config,
  pkgs,
  ...
}: {
  virtualisation.containers.enable = true;
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    defaultNetwork.settings.dns_enabled = true;
  };
  virtualisation.incus.enable = true;

  # Kernel Module Parameters
  # ==
  # Disable power management at driver level during module load
  # boot.extraModprobeConfig = ''
  #   # MT7925 WiFi - disable all power management for stability
  #   options mt7925e disable_aspm=1
  #   options mt7925e power_save=0

  #   # Disable CLC (Country Location Code) - fixes 6GHz band stability
  #   options mt7925-common disable_clc=1
  # '';
}
