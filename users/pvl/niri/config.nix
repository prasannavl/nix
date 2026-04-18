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
  wallpaper = ../../../data/backgrounds/sw.png;
  cursorTheme = "Adwaita";
  cursorSize = 24;

  # Runtime reference: /run/current-system/sw/share/doc/niri/default-config.kdl
  defaultConfig = builtins.readFile "${pkgs.niri.doc}/share/doc/niri/default-config.kdl";
  baseConfig =
    builtins.replaceStrings
    [
      ''spawn-at-startup "waybar"''
    ]
    [
      ""
    ]
    defaultConfig;

  nixConfig = ''
    // Nix-managed overlay.

    // prefer-no-csd
    screenshot-path "~/Pictures/Screenshots/%Y-%m-%d %H-%M-%S.png"

    input {
        touchpad {
            tap
            dwt
            dwtp
            natural-scroll
            tap-button-map "left-right-middle"
        }
        mouse {
            // accel-speed 0.2
            // accel-profile "adaptive"
        }
        workspace-auto-back-and-forth
    }

    layout {
        gaps 2
        always-center-single-column
        focus-ring {
            // off
            width 2
            // active-color "#9de7ff"
        }
        shadow {
            // on
            draw-behind-window true
        }
        tab-indicator {
            place-within-column
        }
    }

    hotkey-overlay {
        skip-at-startup
    }

    animations {
        off
        // slowdown 0.5
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

    environment {
        XDG_CURRENT_DESKTOP "niri"
        XDG_SESSION_DESKTOP "niri"
        DESKTOP_SESSION "niri"
    }

    cursor {
        xcursor-theme "${cursorTheme}"
        xcursor-size ${toString cursorSize}
    }

    xwayland-satellite {
        path "${xwaylandSatellite}"
    }


    spawn-at-startup "${pkgs.swaybg}/bin/swaybg" "-m" "fill" "-i" "${wallpaper}"

    binds {
        Mod+T hotkey-overlay-title="Open a Terminal: alacritty" { spawn "${terminal}"; }
        Super+Alt+L hotkey-overlay-title="Lock the Screen: swaylock" { spawn "${lockCmd}"; }

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

        // Custom keybinds: deliberate overrides/additions from Niri defaults.
        Mod+D hotkey-overlay-title="Run an Application: Noctalia Launcher" { spawn-sh "${launcher} || ${runner}"; }
        Ctrl+Print hotkey-overlay-title="Screenshot Screen to Clipboard" { screenshot-screen write-to-disk=false; }
        Alt+Print hotkey-overlay-title="Screenshot Window to Clipboard" { screenshot-window write-to-disk=false; }
    }

    window-rule {
        match app-id="org.pulseaudio.pavucontrol"
        open-floating true
    }

    window-rule {
        match app-id="Alacritty"
        geometry-corner-radius 12
        clip-to-geometry true
    }
  '';
  configSeed = pkgs.writeText "niri-config.kdl" ''
    // Local Niri config. This file is intentionally not managed by Nix.
    // Comment either include when you want to opt out locally.
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
  };
}
