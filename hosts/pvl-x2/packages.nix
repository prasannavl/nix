{ config, pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    vim
    tmux
    wget
    htop
    curl
   
    bash-completion
    neovim
    ranger
    fd
    ripgrep
   
    pciutils
    tmux
    mesa-demos
    libva-utils
    vulkan-tools
    wdisplays
    iperf3

    sway
    fuzzel
    alacritty
    foot
    wl-clipboard
    wmenu
    xdg-desktop-portal-wlr
    
    podman-compose
    cloudflared
    tailscale

    vlc
    pavucontrol
    alsa-utils

    gnome-tweaks
    git
    tree
    nvd

    sbctl
    tpm2-tools
    dmidecode
    age
  ];
}
