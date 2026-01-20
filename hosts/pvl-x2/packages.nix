{ config, pkgs, ... }: let
  # Keep groups isolated so they can be lifted into lib/profiles later.
  packages = {
    core = with pkgs; [
      vim
      wget
      htop
      curl
      bash-completion
      fd
      ripgrep
      ranger
      tree
      git
    ];

    wayland = with pkgs; [
      alacritty
      foot
      wl-clipboard
    ];

    sway = with pkgs; [
      sway
      fuzzel
      wmenu
      xdg-desktop-portal-wlr
      wdisplays
    ];

    gnome = with pkgs; [
      gnome-tweaks
    ];

    audioVideo = with pkgs; [
      vlc
      pavucontrol
      alsa-utils
    ];

    graphics = with pkgs; [
      mesa-demos
      libva-utils
      vulkan-tools
    ];

    network = with pkgs; [
      iperf3
      cloudflared
      tailscale
    ];

    containers = with pkgs; [
      podman-compose
    ];

    hardware = with pkgs; [
      pciutils
      dmidecode
      tpm2-tools
    ];

    security = with pkgs; [
      sbctl
      age
    ];

    nixTools = with pkgs; [
      nvd
    ];

    misc = with pkgs; [
    ];
  };
in {
  # Toggle whole groups by commenting out the line below.
  environment.systemPackages =
    packages.core
    ++ packages.wayland
    ++ packages.sway
    ++ packages.gnome
    ++ packages.audioVideo
    ++ packages.graphics
    ++ packages.network
    ++ packages.containers
    ++ packages.hardware
    ++ packages.security
    ++ packages.nixTools
    ++ packages.misc;
}
