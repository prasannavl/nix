{pkgs, ...}: let
  # Keep groups isolated so they can be lifted into lib/profiles later.
  packages = {
    core = with pkgs; [
      wget
      curl
      fd
      ripgrep
      ranger
      tree
      nvtopPackages.full
      socat
      dig
      sysstat
    ];

    gnome = with pkgs; [
      gnome-tweaks
    ];

    media = with pkgs; [
      vlc
      pavucontrol
      alsa-utils
    ];

    graphics = with pkgs; [
      mesa-demos
      libva-utils
      vulkan-tools
    ];

    dev = with pkgs; [
      gdb
      vim.xxd
      fish
    ];

    db = with pkgs; [
      postgresql_18
    ];

    network = with pkgs; [
      iperf3
      cloudflared
      tailscale
    ];

    monitoring = with pkgs; [
      nethogs
    ];

    containers = [
    ];

    hardware = with pkgs; [
      pciutils
      dmidecode
      tpm2-tools
      ddcutil
      powertop
      brightnessctl
      smartmontools
      nvme-cli
      e2fsprogs
      lm_sensors
    ];

    security = with pkgs; [
      sbctl
      age
    ];

    nixTools = with pkgs; [
      nvd
    ];
  };
in {
  # Toggle whole groups by commenting out the line below.
  environment.systemPackages =
    packages.core
    ++ packages.gnome
    ++ packages.media
    ++ packages.graphics
    ++ packages.dev
    ++ packages.db
    ++ packages.network
    ++ packages.monitoring
    ++ packages.containers
    ++ packages.hardware
    ++ packages.security
    ++ packages.nixTools;
}
