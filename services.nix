{ config, pkgs, ... }:
{
  services.resolved.enable = true;
  services.seatd.enable = true;
  services.openssh.enable = true;
  services.tailscale.enable = true;
  
  services.printing.enable = true;
  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  services.pulseaudio.enable = false;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    #jack.enable = true;
  };

  services.xserver.enable = true;
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  services.gnome.gnome-remote-desktop.enable = true;
  services.fail2ban.enable = true;
  services.flatpak.enable = true;

  services.udev.extraHwdb = ''
    # AT Translated Set 2 keyboard
    evdev:name:AT Translated Set 2 keyboard:*
     KEYBOARD_KEY_dd=sysrq

    # Asus WMI hotkeys
    evdev:name:Asus WMI hotkeys:*
     KEYBOARD_KEY_38=sysrq
  '';

  services.keyd = {
    enable = true;
    keyboards = {
      default = {
        ids = [ "0001:0001:3cf016cc" ];
        settings = {
          main = {
            "leftmeta+leftshift+f23" = "layer(control)";
          };
        };
      };
    };
  };

  services.logind = {
    lidSwitch = "suspend";
    lidSwitchExternalPower = "ignore";
    lidSwitchDocked = "ignore";
  };

  systemd.settings.Manager = {
    # Notify pre-timeout
    RuntimeWatchdogPreSec = "60s";
    # Reboot if PID 1 hangs (set to "off" to disable)
    RuntimeWatchdogSec = "off";
    # HW watchdog reset limit during shutdown/reboot
    RebootWatchdogSec = "5min";
    DefaultLimitNOFILE = "1048576";
  };

  # user conf
  systemd.user.extraConfig = ''
    DefaultLimitNOFILE=1048576
  '';
}
