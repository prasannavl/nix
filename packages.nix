{ config, pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    vim tmux wget htop curl
    bash-completion fd ripgrep 
    pciutils tmux mesa-demos libva-utils vulkan-tools wdisplays iperf3
    sway fuzzel alacritty foot wl-clipboard wmenu xdg-desktop-portal-wlr
    podman-compose cloudflared tailscale
    vlc pavucontrol alsa-utils
    gnome-tweaks nvtopPackages.full
    git tree lazygit
    nvd nix-index
    tree dconf-editor
    google-chrome
    ddcutil
    obsidian zed-editor
    solaar
    gnome-power-manager dmidecode powertop
    brightnessctl ghostty ente-auth
    ranger imagemagick
  ];

  fonts.packages = with pkgs; [
    noto-fonts
  ];
}
