{
  config,
  lib,
  pkgs,
  ...
}: let
  terminal = "${pkgs.alacritty}/bin/alacritty";
  runner = "${pkgs.fuzzel}/bin/fuzzel --list-executables-in-path";
  launcher = "${config.programs.noctalia-shell.package}/bin/noctalia-shell ipc call launcher toggle";
  lockCmd = "${pkgs.swaylock}/bin/swaylock -f -c 000000 --indicator-idle-visible";
  grimshot = "${pkgs.sway-contrib.grimshot}/bin/grimshot";
  wpctl = "${pkgs.wireplumber}/bin/wpctl";
  playerctl = "${pkgs.playerctl}/bin/playerctl";
  brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
  xwaylandSatellite = "${pkgs.xwayland-satellite}/bin/xwayland-satellite";
  cursorTheme = "Adwaita";
  cursorSize = 24;

  wmServices = import ../wm/services.nix {};
  idle = import ../wm/idle.nix {inherit pkgs;};
  outputs = import ../wm/outputs.nix;
  renderOutputDefaults = output: ''
    output "${output.name}" {
        mode "${lib.removeSuffix "Hz" output.mode}"
        scale ${output.scale}
        transform "${output.transform}"
        ${lib.optionalString output.vrr "variable-refresh-rate"}
    }
  '';
  outputDefaults = lib.concatMapStringsSep "\n\n" renderOutputDefaults outputs.all;

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
      ''Print { screenshot; }''
      ''Ctrl+Print { screenshot-screen; }''
      ''Alt+Print { screenshot-window; }''
      ''Super+Alt+L hotkey-overlay-title="Lock the Screen: swaylock" { spawn "swaylock"; }''
      ''Mod+Escape allow-inhibiting=false { toggle-keyboard-shortcuts-inhibit; }''
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
      ""
      ""
      ""
      ""
      ''Mod+Shift+Escape allow-inhibiting=false { toggle-keyboard-shortcuts-inhibit; }''
    ]
    defaultConfig;

  nixConfig = ''
    // Nix-managed overlay.

    debug {
        render-drm-device "/dev/dri/zrender-default"
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

    spawn-at-startup "${pkgs.systemd}/bin/systemctl" "--user" "--no-block" "start" "${wmServices.readyTargetUnits.niri}"

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
    }

    animations {
        on
        slowdown 0.1
        workspace-switch {
            off
        }
    }

    overview {
        zoom 0.25
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
        // center-focused-column "on-overflow"
        default-column-width {}

        border {
            on
            width 2
            active-color "rgb(58, 101, 154)"
            inactive-color "rgb(62, 62, 62)"
            urgent-color "#d83d3a"
        }

        tab-indicator {
            hide-when-single-tab
            place-within-column
            // corner-radius 10
            position "left"
            gap 0
            width 8
            length total-proportion=0.998
            active-color "rgb(200, 200, 200)"
            inactive-color "#303030"
        }

        focus-ring {
            off
        }
    }

    include "binds.kdl"

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

        border {
            active-color "#dcc156"
            inactive-color "#b3ad65"
        }

        focus-ring {
            active-color "#ccb766"
            inactive-color "#b3ad65"
        }
    }

    // Per app rules

    window-rule {
        match app-id="org.pulseaudio.pavucontrol"
        open-floating true
        default-floating-position x=0 y=0 relative-to="top-right"
    }

    include "output-defaults.kdl"
    include "output-rules.kdl"
    include "window-rules-corners.kdl"
  '';
  binds = ''
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

        // Other navigation

        Mod+Ctrl+WheelScrollLeft  { move-column-left; }
        Mod+Ctrl+WheelScrollRight { move-column-right; }

        // Screenshots

        Print hotkey-overlay-title="Screenshot Selection" { screenshot; }
        Shift+Print hotkey-overlay-title="Screenshot Screen" { screenshot-screen; }
        Alt+Print hotkey-overlay-title="Screenshot Window" { screenshot-window; }
        Ctrl+Print hotkey-overlay-title="Screenshot Selection to Clipboard" { spawn "${grimshot}" "copy" "area"; }
        Ctrl+Shift+Print hotkey-overlay-title="Screenshot Screen to Clipboard" { screenshot-screen write-to-disk=false; }
        Ctrl+Alt+Print hotkey-overlay-title="Screenshot Window to Clipboard" { screenshot-window write-to-disk=false; }
        Mod+X hotkey-overlay-title="Screenshot Selection" { screenshot; }
        Mod+Shift+X hotkey-overlay-title="Screenshot Screen" { screenshot-screen; }
        Mod+Alt+X hotkey-overlay-title="Screenshot Window" { screenshot-window; }
        Mod+Ctrl+X hotkey-overlay-title="Screenshot Selection to Clipboard" { spawn "${grimshot}" "copy" "area"; }
        Mod+Ctrl+Shift+X hotkey-overlay-title="Screenshot Screen to Clipboard" { screenshot-screen write-to-disk=false; }
        Mod+Ctrl+Alt+X hotkey-overlay-title="Screenshot Window to Clipboard" { screenshot-window write-to-disk=false; }

        // Common applications

        Mod+Return hotkey-overlay-title="Open a Terminal: alacritty" { spawn "${terminal}"; }

        Mod+D hotkey-overlay-title="Run an Application: Noctalia Launcher" { spawn-sh "${runner} || ${launcher}"; }

        Mod+Space hotkey-overlay-title="Run an Application: Noctalia Launcher" { spawn-sh "${launcher} || ${runner}"; }

        Mod+Escape hotkey-overlay-title="Lock the Screen: swaylock" { spawn "${lockCmd}"; }

        Mod+Z { spawn "systemctl" "--user" "restart" "kanshi" "noctalia-shell"; }
    }
  '';
  outputRules = ''
    // Per-output layout rules

    output "${outputs.lg-uw3840.name}" {
        focus-at-startup
        layout {
            always-center-single-column
            // default-column-width { proportion 0.6; }
            preset-column-widths {
                proportion 0.25
                proportion 0.5
                proportion 0.6
            }
        }
    }

    output "${outputs.a1.name}" {
        focus-at-startup
        layout {
            // default-column-width { proportion 0.8; }
            preset-column-widths {
                proportion 0.5
                proportion 0.8
                proportion 0.9
            }
        }
    }
  '';
  windowRulesCorners = ''
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
    // nix-config.kdl includes binds.kdl, output-defaults.kdl,
    // output-rules.kdl, and window-rules-corners.kdl.
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
    "niri/binds.kdl".text = binds;
    "niri/output-defaults.kdl".text = ''
      // Shared output defaults generated from users/pvl/wm/outputs.nix.
      // This lets Niri start with the intended mode/scale/transform/VRR
      // before kanshi applies the current topology profile and positions.
      ${outputDefaults}
    '';
    "niri/output-rules.kdl".text = outputRules;
    "niri/window-rules-corners.kdl".text = windowRulesCorners;
  };

  systemd.user.services.swayidle-niri = idle.mkIdleService {
    name = "wm-swayidle-niri";
    description = "Idle manager for Niri";
    readyTarget = wmServices.readyTargetUnits.niri;
    sessionUnit = wmServices.sessionUnits.niri;
    powerOffCommand = "${pkgs.niri}/bin/niri msg action power-off-monitors";
    powerOnCommand = "${pkgs.niri}/bin/niri msg action power-on-monitors";
  };
}
