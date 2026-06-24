{
  nixos = {...}: {};

  home = {config, ...}: let
    wmServices = import ../wm/services.nix {};
    monochromeScheme = import ./colorscheme.nix;
    barSettings = import ./bar.nix;
    controlCenterSettings = import ./control-center.nix;
    pluginConfig = import ./plugins.nix;
    dockEnabled = true;
    powerOption = action: keybind: {
      action = action;
      keybind = keybind;
      command = "";
      countdownEnabled = true;
      enabled = true;
    };
  in {
    programs.noctalia-shell = {
      enable = true;

      settings = {
        settingsVersion = 59;

        appLauncher = {
          enableClipboardHistory = true;
          iconMode = "native";
          position = "top_center";
          pinnedApps = [
            "Alacritty"
            "google-chrome"
            "code"
            "org.gnome.Nautilus"
            "chrome-cadlkienfkclaiaibeoongdcgmdikeeg-Default"
            "org.gnome.Calendar"
            "org.gnome.clocks"
            "org.gnome.Characters"
            "org.gnome.Calculator"
          ];
        };

        audio.volumeOverdrive = true;

        bar = barSettings;

        brightness.enableDdcSupport = true;

        colorSchemes = {
          generationMethod = "muted";
          predefinedScheme = "Monochrome";
        };

        controlCenter = controlCenterSettings;

        dock =
          if !dockEnabled
          then false
          else {
            enabled = true;
            position = "top";
            size = 1.25;
            floatingRatio = 0;
            pinnedApps = [
              "Alacritty"
              "google-chrome"
              "code"
              "org.gnome.Calendar"
              "org.gnome.clocks"
              "chrome-cadlkienfkclaiaibeoongdcgmdikeeg-Default"
            ];
            pinnedStatic = true;
            groupApps = true;
            inactiveIndicators = true;
            showLauncherIcon = true;
            showDockIndicator = true;
            launcherPosition = "start";
            launcherUseDistroLogo = true;
            indicatorColor = "none";
            indicatorOpacity = 0.25;
          };

        general = {
          animationDisabled = true;
          animationSpeed = 2;
          compactLockScreen = true;
          dimmerOpacity = 0;
          enableBlurBehind = false;
          enableShadows = false;
          iRadiusRatio = 0.35;
          lockOnSuspend = false;
          radiusRatio = 0.2;
          scaleRatio = 1.2;
          showChangelogOnStartup = false;
          smoothScrollEnabled = false;
        };

        location = {
          autoLocate = true;
          showWeekNumberInCalendar = true;
        };

        network.bluetoothRssiPollIntervalMs = 10000;

        notifications = {
          backgroundOpacity = 0.8;
          enableMarkdown = true;
          location = "top";
          sounds.enabled = true;
        };

        plugins.autoUpdate = true;

        sessionMenu = {
          largeButtonsLayout = "grid";
          largeButtonsStyle = false;
          position = "top_right";
          powerOptions = [
            (powerOption "lock" "1")
            (powerOption "suspend" "2")
            (powerOption "hibernate" "3")
            (powerOption "reboot" "4")
            (powerOption "logout" "5")
            (powerOption "shutdown" "6")
            (powerOption "rebootToUefi" "7")
            (powerOption "userspaceReboot" "8")
          ];
        };

        systemMonitor = {
          criticalColor = "#bf616a";
          warningColor = "#5e81ac";
        };

        ui = {
          fontDefault = "Noto Sans";
          fontFixed = "Noto Sans Mono";
          panelBackgroundOpacity = 1;
          panelsAttachedToBar = false;
          tooltipsEnabled = false;
        };

        wallpaper = {
          directory = "/home/pvl/Pictures/Wallpapers";
          enabled = false;
        };
      };

      plugins = pluginConfig.plugins;

      pluginSettings = pluginConfig.pluginSettings;
    };

    xdg.configFile."noctalia/colorschemes/Monochrome/Monochrome.json".text =
      builtins.toJSON monochromeScheme;

    systemd.user.services.noctalia-shell =
      wmServices.mkWmPostService
      "Noctalia Shell"
      "${config.programs.noctalia-shell.package}/bin/noctalia-shell";
  };
}
