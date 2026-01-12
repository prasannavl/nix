{
  config,
  pkgs,
  ...
}: {
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    nssmdns6 = true;
  };

  services.resolved = {
    enable = true;
    # Choose one mDNS stack, avahi is nicer.
    extraConfig = ''
      MulticastDNS=no
    '';
  };

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
    wireplumber.enable = true;
    #jack.enable = true;
  };

  services.xserver.enable = true;
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  services.fail2ban.enable = true;
  services.fwupd.enable = true;

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
        ids = ["0001:0001:3cf016cc"];
        settings = {
          main = {
            "leftmeta+leftshift+f23" = "layer(control)";
          };
        };
      };
    };
  };
}
