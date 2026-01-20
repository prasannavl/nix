{
  config,
  pkgs,
  inputs,
  ...
}: let
  llm-agent-pkgs = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
  antigravity-pkgs = inputs.antigravity.packages.${pkgs.stdenv.hostPlatform.system};
  codex-pkgs = inputs.codex.packages.${pkgs.stdenv.hostPlatform.system};
  # Keep groups isolated so they can be lifted into lib/profiles later.
  packages = {
    core = with pkgs; [
      wget
      curl
      fd
      ripgrep
      jq
      tree
      lazygit
      ranger
      nvtopPackages.full
    ];

    wayland = with pkgs; [
      alacritty
      foot
      ghostty
      wl-clipboard
      xdg-utils
      xdg-user-dirs
    ];

    sway = with pkgs; [
      sway
      fuzzel
      wmenu
      xdg-desktop-portal-wlr
      wdisplays
    ];

    gnome = with pkgs; [
      gnome-control-center
      gnome-tweaks
      gnome-power-manager
      dconf-editor
    ];

    audioVideo = with pkgs; [
      vlc
      pavucontrol
      alsa-utils
      cheese
    ];

    productivity = with pkgs; [
      google-chrome
      obsidian
      libreoffice
      xournalpp
      inkscape
      gimp
      imagemagick
    ];

    graphics = with pkgs; [
      mesa-demos
      libva-utils
      vulkan-tools
    ];

    dev = with pkgs; [
      python3
      gnumake
      rustup
      cargo
      rustc
      rustfmt
      rust-analyzer
      zed-editor
    ];

    nixTools = with pkgs; [
      nvd
      nix-index
      hydra-check
      cachix
    ];

    containers = with pkgs; [
      podman-compose
      distrobox
      crun
      runc
    ];

    network = with pkgs; [
      cloudflared
      tailscale
      iperf3
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

    inputDebug = with pkgs; [
      xorg.xev
      xorg.xeyes
      xprop
      xset
      v4l-utils
      evtest
      wev
    ];

    security = with pkgs; [
      git-secrets
      git-crypt
      git-credential-manager
      sops
      age
      sbctl
      ente-auth
    ];

    ai = with pkgs; [
      jan
      antigravity-pkgs.default
      codex-pkgs.default
    ];

    misc = with pkgs; [
    ];

    fonts = with pkgs; [
      noto-fonts
      dejavu_fonts
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
    ++ packages.productivity
    ++ packages.graphics
    ++ packages.dev
    ++ packages.nixTools
    ++ packages.containers
    ++ packages.network
    ++ packages.hardware
    ++ packages.inputDebug
    ++ packages.security
    ++ packages.ai
    ++ packages.misc;

  fonts.packages = packages.fonts;

  programs = { 
    seahorse.enable = true;
    tcpdump.enable = true;
    wireshark.enable = true;
    nix-index.enable = true;
    atop.enable = true;
    ryzen-monitor-ng.enable = true;
  };
}
