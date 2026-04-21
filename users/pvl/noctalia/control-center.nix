let
  widget = id: {id = id;};
  enabledCard = id: {
    id = id;
    enabled = true;
  };
in {
  cards = [
    (enabledCard "profile-card")
    (enabledCard "shortcuts-card")
    (enabledCard "audio-card")
    (enabledCard "brightness-card")
    (enabledCard "weather-card")
    (enabledCard "media-sysmon-card")
  ];
  shortcuts = {
    left = [
      (widget "AirplaneMode")
      (widget "WiFi")
      (widget "Bluetooth")
      (widget "Network")
    ];
    right = [
      (widget "KeepAwake")
      (widget "DarkMode")
      (widget "NightLight")
      (widget "plugin:screen-recorder")
    ];
  };
}
