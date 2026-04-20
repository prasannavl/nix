{
  config,
  lib,
  pkgs,
  ...
}: let
  terminal = "${pkgs.alacritty}/bin/alacritty";
  runner = "${pkgs.fuzzel}/bin/fuzzel --list-executables-in-path";
  launcher = "${config.programs.noctalia-shell.package}/bin/noctalia-shell ipc call launcher toggle";
  lockCmd = "${pkgs.swaylock}/bin/swaylock";
  wpctl = "${pkgs.wireplumber}/bin/wpctl";
  playerctl = "${pkgs.playerctl}/bin/playerctl";
  brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
  xwaylandSatellite = "${pkgs.xwayland-satellite}/bin/xwayland-satellite";
  cursorTheme = "Adwaita";
  cursorSize = 24;

  # Runtime reference: /run/current-system/sw/share/doc/niri/default-config.kdl
  defaultConfig = builtins.readFile "${pkgs.niri.doc}/share/doc/niri/default-config.kdl";
  baseConfig =
    builtins.replaceStrings
    [
      ''spawn-at-startup "waybar"''
      "Mod+Ctrl+Left"
      "Mod+Ctrl+Down"
      "Mod+Ctrl+Up"
      "Mod+Ctrl+Right"
      "Mod+Ctrl+H"
      "Mod+Ctrl+J"
      "Mod+Ctrl+K"
      "Mod+Ctrl+L"
      "Mod+Shift+Left"
      "Mod+Shift+Down"
      "Mod+Shift+Up"
      "Mod+Shift+Right"
      "Mod+Shift+H"
      "Mod+Shift+J"
      "Mod+Shift+K"
      "Mod+Shift+L"
      "Mod+Ctrl+Home"
      "Mod+Ctrl+End"
      "Mod+Ctrl+Page_Down"
      "Mod+Ctrl+Page_Up"
      "Mod+Ctrl+U"
      "Mod+Ctrl+I"
      "Mod+Shift+Page_Down"
      "Mod+Shift+Page_Up"
      "Mod+Shift+U"
      "Mod+Shift+I"
      "Mod+Ctrl+WheelScrollDown"
      "Mod+Ctrl+WheelScrollUp"
      "Mod+Shift+WheelScrollDown"
      "Mod+Shift+WheelScrollUp"
      "Mod+Ctrl+WheelScrollRight"
      "Mod+Ctrl+WheelScrollLeft"
      "Mod+Ctrl+1"
      "Mod+Ctrl+2"
      "Mod+Ctrl+3"
      "Mod+Ctrl+4"
      "Mod+Ctrl+5"
      "Mod+Ctrl+6"
      "Mod+Ctrl+7"
      "Mod+Ctrl+8"
      "Mod+Ctrl+9"
    ]
    [
      ""
      "Mod+Shift+Left"
      "Mod+Shift+Down"
      "Mod+Shift+Up"
      "Mod+Shift+Right"
      "Mod+Shift+H"
      "Mod+Shift+J"
      "Mod+Shift+K"
      "Mod+Shift+L"
      "Mod+Ctrl+Left"
      "Mod+Ctrl+Down"
      "Mod+Ctrl+Up"
      "Mod+Ctrl+Right"
      "Mod+Ctrl+H"
      "Mod+Ctrl+J"
      "Mod+Ctrl+K"
      "Mod+Ctrl+L"
      "Mod+Shift+Home"
      "Mod+Shift+End"
      "Mod+Shift+Page_Down"
      "Mod+Shift+Page_Up"
      "Mod+Shift+U"
      "Mod+Shift+I"
      "Mod+Ctrl+Page_Down"
      "Mod+Ctrl+Page_Up"
      "Mod+Ctrl+U"
      "Mod+Ctrl+I"
      "Mod+Shift+WheelScrollDown"
      "Mod+Shift+WheelScrollUp"
      "Mod+Ctrl+WheelScrollDown"
      "Mod+Ctrl+WheelScrollUp"
      "Mod+Shift+WheelScrollRight"
      "Mod+Shift+WheelScrollLeft"
      "Mod+Shift+1"
      "Mod+Shift+2"
      "Mod+Shift+3"
      "Mod+Shift+4"
      "Mod+Shift+5"
      "Mod+Shift+6"
      "Mod+Shift+7"
      "Mod+Shift+8"
      "Mod+Shift+9"
    ]
    defaultConfig;

  nixConfig = ''
    // Nix-managed overlay.

    debug {
        render-drm-device "/dev/dri/renderD128"
        // Work around PipeWire screencast renegotiation issues seen with
        // GNOME Network Displays under Niri; see niri issue #2223 and
        // GNOME Network Displays work item #460.
        // Still doesn't solve it, including:
        // restrict-primary-scanout-to-matching-format
        // disable-direct-scanout
        // force-pipewire-invalid-modifier
    }

    cursor {
        xcursor-theme "${cursorTheme}"
        xcursor-size ${toString cursorSize}
    }

    xwayland-satellite {
        path "${xwaylandSatellite}"
    }

    input {
        touchpad {
            tap
            dwt
            dwtp
            natural-scroll
            tap-button-map "left-right-middle"
        }
        workspace-auto-back-and-forth
    }

    environment {
        XDG_CURRENT_DESKTOP "niri"
        XDG_SESSION_DESKTOP "niri"
        DESKTOP_SESSION "niri"
        ELECTRON_OZONE_PLATFORM_HINT "auto"
    }

    animations {
        on
        slowdown 0.1
        workspace-switch {
            off
        }
    }

    overview {
        zoom 0.4
        workspace-shadow {
            // off
        }
    }

    hotkey-overlay {
        skip-at-startup
    }

    layout {
        gaps 0
        always-center-single-column
        background-color "transparent"
        default-column-width {}

        border {
            on
            width 2
            active-color "rgb(58, 101, 154)"
            inactive-color "rgb(62, 62, 62)"
            urgent-color "#eec64f"
        }

        tab-indicator {
            gap 0
            width 4
            position "top"
            hide-when-single-tab
            place-within-column
            active-color "rgb(157, 179, 97)"
            inactive-color "#303030"
        }

        focus-ring {
            off
        }
    }

    binds {
        XF86AudioRaiseVolume allow-when-locked=true { spawn "${wpctl}" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1+" "-l" "1.0"; }
        XF86AudioLowerVolume allow-when-locked=true { spawn "${wpctl}" "set-volume" "@DEFAULT_AUDIO_SINK@" "0.1-"; }
        XF86AudioMute allow-when-locked=true { spawn "${wpctl}" "set-mute" "@DEFAULT_AUDIO_SINK@" "toggle"; }
        XF86AudioMicMute allow-when-locked=true { spawn "${wpctl}" "set-mute" "@DEFAULT_AUDIO_SOURCE@" "toggle"; }
        XF86AudioPlay allow-when-locked=true { spawn "${playerctl}" "play-pause"; }
        XF86AudioStop allow-when-locked=true { spawn "${playerctl}" "stop"; }
        XF86AudioPrev allow-when-locked=true { spawn "${playerctl}" "previous"; }
        XF86AudioNext allow-when-locked=true { spawn "${playerctl}" "next"; }
        XF86MonBrightnessUp allow-when-locked=true { spawn "${brightnessctl}" "--class=backlight" "set" "+10%"; }
        XF86MonBrightnessDown allow-when-locked=true { spawn "${brightnessctl}" "--class=backlight" "set" "10%-"; }

        // Dynamic screencast target.
        Mod+Shift+W { set-dynamic-cast-window; }
        Mod+Shift+M { set-dynamic-cast-monitor; }
        Mod+Shift+C { clear-dynamic-cast-target; }

        // Move the current workspace across monitors.
        Mod+Ctrl+Alt+Left  { move-workspace-to-monitor-left; }
        Mod+Ctrl+Alt+Down  { move-workspace-to-monitor-down; }
        Mod+Ctrl+Alt+Up    { move-workspace-to-monitor-up; }
        Mod+Ctrl+Alt+Right { move-workspace-to-monitor-right; }
        Mod+Ctrl+Alt+H     { move-workspace-to-monitor-left; }
        Mod+Ctrl+Alt+J     { move-workspace-to-monitor-down; }
        Mod+Ctrl+Alt+K     { move-workspace-to-monitor-up; }
        Mod+Ctrl+Alt+L     { move-workspace-to-monitor-right; }

        // Full screen and mirroring

        Mod+Ctrl+Shift+F { toggle-windowed-fullscreen; }
        Mod+P repeat=false { spawn-sh "wl-mirror $(niri msg --json focused-output | jq -r .name)"; }

        // Screenshots

        Ctrl+Print hotkey-overlay-title="Screenshot Screen to Clipboard" { screenshot-screen write-to-disk=false; }
        Alt+Print hotkey-overlay-title="Screenshot Window to Clipboard" { screenshot-window write-to-disk=false; }

        // Common applications

        Mod+Return hotkey-overlay-title="Open a Terminal: alacritty" { spawn "${terminal}"; }

        Mod+D hotkey-overlay-title="Run an Application: Noctalia Launcher" { spawn-sh "${launcher} || ${runner}"; }

        Mod+Space hotkey-overlay-title="Run an Application: Noctalia Launcher" { spawn-sh "${launcher} || ${runner}"; }

        Super+Alt+L hotkey-overlay-title="Lock the Screen: swaylock" { spawn "${lockCmd}"; }
    }

    // Top levels

    // prefer-no-csd
    screenshot-path "~/Pictures/Screenshots/%Y-%m-%d %H-%M-%S.png"

    // General rules

    layer-rule {
        match namespace="^launcher$"
    }

    layer-rule {
        match namespace="^wallpaper$"
        // place-within-backdrop true
    }

    layer-rule {
        match namespace="^notifications$"
        block-out-from "screencast"
    }

    window-rule {
        match is-window-cast-target=true

        focus-ring {
            active-color "#ccb766"
            inactive-color "#b3ad65"
        }

        border {
            active-color "#dcc156"
            inactive-color "#b3ad65"
        }
    }

    // Per app rules

    window-rule {
        match app-id="org.pulseaudio.pavucontrol"
        open-floating true
    }

    include "corner-rules.kdl"
  '';
  cornerRules = ''
    // Per-app corner radius rules

    window-rule {
        // @adwPreset: radius 18
        match app-id=r#"^org\.gnome.*"#
        match app-id=r#"^com\.github\.tchx84\.Flatseal$"#
        match app-id=r#"^simple-scan$"#
        match app-id=r#"^re\.sonny\.Workbench$"#
        match app-id=r#"^com\.mattjakeman\.ExtensionManager$"#
        match app-id=r#"^com\.mitchellh\.ghostty$"#

        geometry-corner-radius 18
        clip-to-geometry true
    }

    window-rule {
        // @gtkPreset: radius { tl: 10, tr: 10, br: 0, bl: 0 }
        match app-id=r#"^org\.gnome\.Terminal$"#
        match app-id=r#"^org\.gnome\.seahorse\.Application$"#
        match app-id=r#"^org\.gnome\.Connections$"#
        match app-id=r#"^firefox$"#
        match app-id=r#"^firefox-esr$"#
        match app-id=r#"^io\.ente\.auth$"#
        match app-id=r#"^dconf-editor$"#
        match app-id=r#"^org\.gimp\.GIMP$"#
        match app-id=r#"^gimp$"#
        match app-id=r#"^org\.inkscape\.Inkscape$"#
        match app-id=r#"^system-config-printer$"#
        match app-id=r#"^libreoffice-calc$"#
        match app-id=r#"^libreoffice-writer$"#
        match app-id=r#"^libreoffice-impress$"#
        match app-id=r#"^libreoffice-draw$"#
        match app-id=r#"^libreoffice-base$"#
        match app-id=r#"^gnome-power-statistics$"#
        match app-id=r#"^cheese$"#
        match app-id=r#"^solaar$"#
        match app-id=r#"^com\.github\.xournalpp\.xournalpp$"#
        match app-id=r#"^gnome-disks$"#
        match app-id=r#"^blender$"#
        match app-id=r#"^fr\.handbrake\.ghb$"#

        geometry-corner-radius 10 10 0 0
        clip-to-geometry true
    }

    window-rule {
        // @chromePreset: radius { tl: 12, tr: 12, br: 0, bl: 0 }
        match app-id=r#"^google-chrome"#
        match app-id=r#"^chrome-"#
        match app-id=r#"^chromium"#
        match app-id=r#"^microsoft-edge$"#
        match app-id=r#"^brave-browser$"#

        geometry-corner-radius 12 12 0 0
        clip-to-geometry true
    }

    window-rule {
        // @zedPreset: radius { tl: 14, tr: 14, br: 10, bl: 10 }
        // Note: original margins preset has no direct niri window-rule equivalent.
        match app-id=r#"^dev\.zed\.Zed$"#

        geometry-corner-radius 14 14 10 10
        clip-to-geometry true
    }

    window-rule {
        // Custom override: Alacritty radius { tl: 12, tr: 12, br: 0, bl: 0 }
        match app-id=r#"^Alacritty$"#

        geometry-corner-radius 12 12 0 0
        clip-to-geometry true
    }

    window-rule {
        // Custom override: gnome-disks radius { tl: 10, tr: 10, br: 11, bl: 11 }
        // Placed after @gtkPreset intentionally to override it.
        match app-id=r#"^gnome-disks$"#

        geometry-corner-radius 10 10 11 11
        clip-to-geometry true
    }
  '';
  configSeed = pkgs.writeText "niri-config.kdl" ''
    // Local Niri config. This file is intentionally not managed by Nix.
    // Comment either include when you want to opt out locally.
    // nix-config.kdl includes corner-rules.kdl.
    // Runtime default reference: /run/current-system/sw/share/doc/niri/default-config.kdl
    include "base-config.kdl"
    include "nix-config.kdl"
  '';
in {
  home.activation.ensureNiriConfig = lib.hm.dag.entryAfter ["writeBoundary"] ''
    local_config="${config.xdg.configHome}/niri/config.kdl"
    if [ ! -e "$local_config" ]; then
        mkdir -p "$(dirname "$local_config")"
        install -m 0644 "${configSeed}" "$local_config"
    fi
  '';

  xdg.configFile = {
    "niri/default-config.kdl".text = defaultConfig;
    "niri/base-config.kdl".text = baseConfig;
    "niri/nix-config.kdl".text = nixConfig;
    "niri/corner-rules.kdl".text = cornerRules;
  };
}
