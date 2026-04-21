let
  pluginSourceUrl = "https://github.com/noctalia-dev/noctalia-plugins";
  pluginIds = [
    "air-quality"
    "kaomoji-provider"
    "privacy-indicator"
    "screen-recorder"
  ];
  pluginState = {
    enabled = true;
    sourceUrl = pluginSourceUrl;
  };
in {
  plugins = {
    version = 2;
    sources = [
      {
        enabled = true;
        name = "Noctalia Plugins";
        url = pluginSourceUrl;
      }
    ];
    states = builtins.listToAttrs (
      map (name: {
        name = name;
        value = pluginState;
      })
      pluginIds
    );
  };

  pluginSettings = {
    air-quality = {
      aqiScale = "us";
      dataSource = "open-meteo";
      aqicnToken = "";
      useNoctaliaLocation = true;
      customLatitude = "";
      customLongitude = "";
      refreshInterval = 30;
      boldText = false;
    };

    privacy-indicator = {
      hideInactive = false;
      enableToast = false;
      removeMargins = false;
      iconSpacing = 4;
      activeColor = "tertiary";
      inactiveColor = "none";
      micFilterRegex = "";
      camFilterRegex = "";
    };

    screen-recorder = {
      hideInactive = false;
      iconColor = "tertiary";
      directory = "";
      filenamePattern = "recording_yyyyMMdd_HHmmss";
      frameRate = "60";
      audioCodec = "opus";
      videoCodec = "h264";
      quality = "very_high";
      colorRange = "limited";
      showCursor = true;
      copyToClipboard = false;
      audioSource = "default_output";
      videoSource = "portal";
      resolution = "original";
      replayEnabled = false;
      replayDuration = "30";
      customReplayDuration = "30";
      replayStorage = "ram";
      restorePortalSession = false;
      customFrameRate = "60";
    };
  };
}
