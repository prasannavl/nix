let
  widget = id: {id = id;};
in {
  backgroundOpacity = 0.5;
  density = "comfortable";
  fontScale = 1.11;
  middleClickAction = "launcherPanel";
  middleClickFollowMouse = true;
  mouseWheelAction = "workspace";
  outerCorners = false;
  widgets = {
    left = [
      {
        id = "Launcher";
        colorizeSystemIcon = "tertiary";
        colorizeSystemText = "none";
        enableColorization = true;
        useDistroLogo = true;
      }
      {
        id = "Workspace";
        emptyColor = "none";
        focusedColor = "error";
        pillSize = 0.75;
        showLabelsOnlyWhenOccupied = false;
      }
      {
        id = "SystemMonitor";
        iconColor = "secondary";
        showDiskAvailable = true;
        showDiskUsage = true;
        showDiskUsageAsPercent = true;
        showLoadAverage = true;
        showMemoryAsPercent = true;
        showNetworkStats = true;
        showSwapUsage = true;
      }
      (widget "MediaMini")
    ];
    center = [
      (widget "plugin:air-quality")
      {
        id = "Clock";
        clockColor = "primary";
        customFont = "Sans Serif";
        formatHorizontal = "yyyy-MM-dd";
        useCustomFont = true;
      }
      {
        id = "Clock";
        clockColor = "error";
        customFont = "Sans Serif";
        formatHorizontal = "HH:mm:ss";
        useCustomFont = true;
      }
      {
        id = "Clock";
        clockColor = "primary";
        customFont = "Sans Serif";
        formatHorizontal = "ddd, MMM d";
        useCustomFont = true;
      }
      {
        id = "KeepAwake";
        iconColor = "tertiary";
        textColor = "tertiary";
      }
    ];
    right = [
      (widget "plugin:privacy-indicator")
      (widget "Tray")
      {
        id = "DarkMode";
        iconColor = "tertiary";
      }
      {
        id = "Network";
        iconColor = "tertiary";
        textColor = "tertiary";
      }
      {
        id = "Bluetooth";
        iconColor = "tertiary";
        textColor = "tertiary";
      }
      (widget "plugin:screen-recorder")
      {
        id = "Volume";
        displayMode = "alwaysShow";
        iconColor = "tertiary";
        textColor = "tertiary";
      }
      {
        id = "Battery";
        displayMode = "icon-always";
        showPowerProfiles = true;
      }
      {
        id = "Brightness";
        displayMode = "alwaysShow";
        iconColor = "tertiary";
        textColor = "tertiary";
      }
      {
        id = "NotificationHistory";
        iconColor = "tertiary";
        unreadBadgeColor = "error";
      }
      {
        id = "ControlCenter";
        colorizeSystemIcon = "tertiary";
        colorizeSystemText = "none";
        enableColorization = true;
        icon = "settings";
      }
    ];
  };
}
