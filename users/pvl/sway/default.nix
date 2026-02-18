{
  nixos = {
    pkgs,
    ...
  }: {
    environment.systemPackages =
      with pkgs; [
        alacritty
        foot
        ghostty
        niri
        wl-clipboard
        xdg-utils
        xdg-user-dirs
        sway
        fuzzel
        wmenu
        xdg-desktop-portal-wlr
        wdisplays
        swayidle
        swaylock
        dmenu
        sway-contrib.grimshot
        grim
        slurp
        brightnessctl
        pavucontrol
        lxqt.lxqt-policykit
        pulseaudio
      ];
  };

  home = {
    config,
    pkgs,
    lib,
    osConfig,
    ...
  }: let
    hostName = osConfig.networking.hostName;
    wlrByHost = {
      pvl-a1 = {
        renderDevice = "/dev/dri/zrender-amd";
        drmDevices = "/dev/dri/zcard-amd:/dev/dri/zcard-nvidia";
      };
    };
    wlrDefaults = {
      renderDevice = "/dev/dri/renderD128";
      drmDevices = "/dev/dri/card0";
    };
    wlrCfg = lib.attrByPath [hostName] wlrDefaults wlrByHost;
    mod = "Mod4";
    terminal = "${pkgs.alacritty}/bin/alacritty";
    menu = "${pkgs.wmenu}/bin/wmenu-run";
    runner = "${pkgs.fuzzel}/bin/fuzzel --list-executables-in-path";
    launcher = "${config.programs.noctalia-shell.package}/bin/noctalia-shell ipc call launcher toggle";
    lockCmd = "${pkgs.swaylock}/bin/swaylock";
    grimshot = "${pkgs.sway-contrib.grimshot}/bin/grimshot";
    grim = "${pkgs.grim}/bin/grim";
    swaymsg = "${pkgs.sway}/bin/swaymsg";
    shikane = "${pkgs.shikane}/bin/shikane";
    lxpolkit = "${pkgs.lxqt.lxqt-policykit}/bin/lxqt-policykit-agent";
    pactl = "${pkgs.pulseaudio}/bin/pactl";
    brightnessctl = "${pkgs.brightnessctl}/bin/brightnessctl";
    pgrep = "${pkgs.procps}/bin/pgrep";
    sudo = "${pkgs.sudo}/bin/sudo";
    systemctl = "${pkgs.systemd}/bin/systemctl";
    which = "${pkgs.which}/bin/which";
    barCmd = "${config.programs.noctalia-shell.package}/bin/noctalia-shell";
    wallpaper = ../../../data/backgrounds/sw.png;
    cursorTheme = "Adwaita";
    cursorSize = 24;
  in {
    wayland.windowManager.sway = {
      enable = true;
      wrapperFeatures.gtk = true;
      extraOptions = ["--unsupported-gpu"];
      extraSessionCommands = ''
        export XDG_CURRENT_DESKTOP="sway"
        export XDG_SESSION_DESKTOP="sway"
        export DESKTOP_SESSION="sway"
        export WLR_RENDER_DRM_DEVICE="${wlrCfg.renderDevice}"
        export WLR_DRM_DEVICES="${wlrCfg.drmDevices}"
      '';
      config = {
        modifier = mod;
        terminal = terminal;
        menu = menu;

        bars = [
          {
            id = "bar-0";
            statusCommand = "-";
            mode = "invisible";
          }
        ];

        input = {
          "type:touchpad" = {
            dwt = "enabled";
            dwtp = "enabled";
            tap = "enabled";
            tap_button_map = "lrm";
            natural_scroll = "enabled";
          };
        };

        output = {
          "*" = {
            bg = "${wallpaper} fill";
          };
        };

        keybindings = {
          "${mod}+Return" = "exec ${terminal}";
          "${mod}+space" = "exec ${runner}";
          "${mod}+d" = "exec ${launcher} || ${runner}";
          "${mod}+x" = "exec ${launcher} || ${runner}";
          "${mod}+Shift+d" = "exec ${menu}";
          "${mod}+Shift+e" = "exec ${swaymsg} exit";
          "${mod}+Shift+c" = "reload";

          "${mod}+h" = "focus left";
          "${mod}+j" = "focus down";
          "${mod}+k" = "focus up";
          "${mod}+l" = "focus right";
          "${mod}+Left" = "focus left";
          "${mod}+Down" = "focus down";
          "${mod}+Up" = "focus up";
          "${mod}+Right" = "focus right";

          "${mod}+Shift+h" = "move left";
          "${mod}+Shift+j" = "move down";
          "${mod}+Shift+k" = "move up";
          "${mod}+Shift+l" = "move right";
          "${mod}+Shift+Left" = "move left";
          "${mod}+Shift+Down" = "move down";
          "${mod}+Shift+Up" = "move up";
          "${mod}+Shift+Right" = "move right";

          "${mod}+Ctrl+Left" = "workspace prev";
          "${mod}+Ctrl+Right" = "workspace next";
          "${mod}+Ctrl+Shift+Left" = "move workspace to output left";
          "${mod}+Ctrl+Shift+Right" = "move workspace to output right";
          "${mod}+1" = "workspace number 1";
          "${mod}+2" = "workspace number 2";
          "${mod}+3" = "workspace number 3";
          "${mod}+4" = "workspace number 4";
          "${mod}+5" = "workspace number 5";
          "${mod}+6" = "workspace number 6";
          "${mod}+7" = "workspace number 7";
          "${mod}+8" = "workspace number 8";
          "${mod}+9" = "workspace number 9";
          "${mod}+0" = "workspace number 10";
          "${mod}+Shift+1" = "move container to workspace number 1";
          "${mod}+Shift+2" = "move container to workspace number 2";
          "${mod}+Shift+3" = "move container to workspace number 3";
          "${mod}+Shift+4" = "move container to workspace number 4";
          "${mod}+Shift+5" = "move container to workspace number 5";
          "${mod}+Shift+6" = "move container to workspace number 6";
          "${mod}+Shift+7" = "move container to workspace number 7";
          "${mod}+Shift+8" = "move container to workspace number 8";
          "${mod}+Shift+9" = "move container to workspace number 9";
          "${mod}+Shift+0" = "move container to workspace number 10";

          "${mod}+q" = "kill";
          "${mod}+Escape" = "exec ${lockCmd}";
          "${mod}+Ctrl+space" = "focus mode_toggle";
          "${mod}+b" = "splith";
          "${mod}+v" = "splitv";
          "${mod}+s" = "layout stacking";
          "${mod}+w" = "layout tabbed";
          "${mod}+e" = "layout toggle split";
          "${mod}+f" = "fullscreen";
          "${mod}+Shift+space" = "floating toggle";
          "${mod}+a" = "focus parent";
          "${mod}+Shift+minus" = "move scratchpad";
          "${mod}+minus" = "scratchpad show";
          "${mod}+r" = "mode resize";

          "${mod}+p" = "exec ${grimshot} savecopy output";
          "${mod}+Ctrl+p" = "exec ${grimshot} copy output";
          "${mod}+Shift+p" = "exec ${grimshot} savecopy active";
          "${mod}+Ctrl+Shift+p" = "exec ${grimshot} copy active";
          "${mod}+z" = "exec ${pgrep} -x ${grimshot} || ${grimshot} savecopy anything";
          "${mod}+Ctrl+z" = "exec ${pgrep} -x ${grimshot} || ${grimshot} copy anything";

          "${mod}+Alt+Left" = "resize shrink width 10 ppt";
          "${mod}+Alt+Right" = "resize grow width 10 ppt";
          "${mod}+Alt+space" = "sticky toggle";
        };

        modes = {
          resize = {
            "h" = "resize shrink width 10px";
            "j" = "resize grow height 10px";
            "k" = "resize shrink height 10px";
            "l" = "resize grow width 10px";
            "Left" = "resize shrink width 10px";
            "Down" = "resize grow height 10px";
            "Up" = "resize shrink height 10px";
            "Right" = "resize grow width 10px";
            "Return" = "mode default";
            "Escape" = "mode default";
            "Ctrl+Left" = "resize shrink width 10 ppt";
            "Ctrl+Down" = "resize grow height 10 ppt";
            "Ctrl+Up" = "resize shrink height 10 ppt";
            "Ctrl+Right" = "resize grow width 10 ppt";
            "Shift+Left" = "resize shrink width 33 ppt";
            "Shift+Down" = "resize grow height 33 ppt";
            "Shift+Up" = "resize shrink height 33 ppt";
            "Shift+Right" = "resize grow width 33 ppt";
          };
        };

        startup = [
          {
            always = true;
            command = "${systemctl} --user restart sway-lxqt-policykit.service";
          }
          {
            always = true;
            command = "${systemctl} --user restart sway-shikane.service";
          }
          {
            always = true;
            command = "${systemctl} --user restart sway-noctalia-shell.service";
          }
        ];

        window.commands = [
          {
            criteria = {
              shell = "xwayland";
            };
            command = "title_format \"[X] %title\"";
          }
          {
            criteria = {
              app_id = "org.pulseaudio.pavucontrol";
            };
            command = "floating enable, sticky enable, move position center";
          }
        ];
      };

      extraConfig = ''
        smart_gaps on
        smart_borders on
        floating_modifier ${mod} normal
        seat * xcursor_theme ${cursorTheme} ${toString cursorSize}

        bindswitch --no-warn --locked --reload lid:on output * power off, exec ${lockCmd}
        bindswitch --no-warn --locked --reload lid:off output * power on

        bindgesture swipe:3:left workspace next
        bindgesture swipe:3:right workspace prev

        bindsym --locked XF86AudioMute exec ${pactl} set-sink-mute @DEFAULT_SINK@ toggle
        bindsym --locked XF86AudioLowerVolume exec ${pactl} set-sink-volume @DEFAULT_SINK@ -5%
        bindsym --locked XF86AudioRaiseVolume exec ${pactl} set-sink-volume @DEFAULT_SINK@ +5%
        bindsym --locked XF86AudioMicMute exec ${pactl} set-source-mute @DEFAULT_SOURCE@ toggle
        bindsym --locked XF86MonBrightnessDown exec ${brightnessctl} set 5%-
        bindsym --locked XF86MonBrightnessUp exec ${brightnessctl} set 5%+
        bindsym Print exec ${grim}

        bindsym --no-repeat --locked --inhibited ${mod}+Alt+g exec ${sudo} $(${which} reset-amdgpu.sh)
        bindsym --inhibited ${mod}+Shift+Escape shortcuts_inhibitor disable
      '';
    };

    xdg.portal = {
      enable = true;
      extraPortals = [
        pkgs.xdg-desktop-portal-wlr
        pkgs.xdg-desktop-portal-gtk
      ];
      config = {
        common.default = "gtk";
        sway = {
          default = ["wlr" "gtk"];
        };
      };
    };

    # Setting this causes gnome's
    # xwayland-native-scaling to not work well.
    # cursor sizes are double divided.
    #
    # home.pointerCursor = {
    #   name = "Adwaita";
    #   package = pkgs.adwaita-icon-theme;
    #   size = 24;
    #   x11.enable = true;
    #   # dotIcons.enable = true;
    # };

    programs.noctalia-shell = {
      enable = true;
    };

    systemd.user.services = {
      sway-lxqt-policykit = {
        Unit = {
          Description = "LXQt PolicyKit Agent for Sway";
          PartOf = ["sway-session.target"];
          After = ["sway-session.target"];
        };
        Service = {
          ExecStart = lxpolkit;
          Restart = "on-failure";
          RestartSec = 1;
        };
        Install.WantedBy = ["sway-session.target"];
      };

      sway-shikane = {
        Unit = {
          Description = "Shikane Output Profile Daemon for Sway";
          PartOf = ["sway-session.target"];
          After = ["sway-session.target"];
        };
        Service = {
          ExecStart = shikane;
          Restart = "on-failure";
          RestartSec = 1;
        };
        Install.WantedBy = ["sway-session.target"];
      };

      sway-noctalia-shell = {
        Unit = {
          Description = "Noctalia Shell for Sway";
          PartOf = ["sway-session.target"];
          After = ["sway-session.target"];
        };
        Service = {
          ExecStart = barCmd;
          Restart = "on-failure";
          RestartSec = 1;
        };
        Install.WantedBy = ["sway-session.target"];
      };
    };
  };
}
