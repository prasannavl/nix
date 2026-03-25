{...}: {
  # MT7921e WiFi
  boot.extraModprobeConfig = ''
    # mt7921e WiFi
    #
    # Disable power management for stability
    options mt7921e disable_aspm=1
    options mt7921e power_save=0

    # Disable CLC (Country Location Code)
    # Higher bands like 6GHz stability fix
    options mt7921_common disable_clc=1
  '';
}
