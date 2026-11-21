{...}: {
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    wireplumber.enable = true;
    #jack.enable = true;
  };

  # For compat
  services.pulseaudio.enable = false;

  # For realtime audio scheduling
  # Pipewire uses rtkit
  security.rtkit.enable = true;
}
