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
}
