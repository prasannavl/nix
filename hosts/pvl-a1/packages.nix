{
  pkgs,
  inputs,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  antigravity-pkgs = inputs.antigravity.packages.${system};
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
      sshfs
      lsof
      socat
      perf
      dig
      sysstat
    ];

    gnome = with pkgs; [
      gnome-control-center
      gnome-tweaks
      gnome-power-manager
      dconf-editor
    ];

    wayland = with pkgs; [
      wl-clipboard-x11
      wl-mirror
      wl-color-picker
      wayscriber
      unstable.wooz
      unstable.chameleos
      showmethekey
      flameshot
    ];

    qtTheming = with pkgs; [
      libsForQt5.qt5ct
      kdePackages.qt6ct
      kdePackages.plasma-integration
    ];

    media = with pkgs; [
      vlc
      mpv
      pavucontrol
      alsa-utils
      cheese
      handbrake-wrapped
      ffmpeg
      catt
      go-chromecast
      gnome-network-displays
      miraclecast
      obs-studio
      shotcut
      kdePackages.kdenlive
      blender
    ];

    terminalRec = with pkgs; [
      asciinema
      asciinema-agg
      figlet
      lolcat
      ascii
      asciigraph
    ];

    productivity = with pkgs; [
      google-chrome
      obsidian
      libreoffice
      xournalpp
      inkscape
      gimp
      imagemagick
      qbittorrent
    ];

    graphics = with pkgs; [
      mesa-demos
      libva-utils
      vulkan-tools
      gtk4
    ];

    dev = with pkgs; [
      (python3.withPackages (ps: with ps; [pip setuptools virtualenv numpy]))
      gnumake
      go
      gopls
      delve
      # rustup
      cargo
      rustc
      rustPlatform.rustLibSrc
      rustfmt
      rust-analyzer
      nodejs
      nodePackages.npm
      yarn
      zed-wrapped
      nixd
      alejandra
      shellcheck
      patchelf
      gdb
      fzf
      vim.xxd
    ];

    db = with pkgs; [
      sqlite
      sqlitebrowser
      sqlitestudio
      sqlitestudio-plugins
      pgsql-tools
      pgadmin4-desktopmode
      postgresql_18
      nats-server
      natscli
      nkeys
      nsc
      # nats-top
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
      nixos-container
    ];

    network = with pkgs; [
      cloudflared
      tailscale
      iperf3
      networkmanagerapplet
      opensnitch
      opensnitch-ui
    ];

    monitoring = with pkgs; [
      nethogs
      wavemon
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
      age
      sbctl
      ente-auth
      openssl
    ];

    ai = with pkgs; [
      jan
      antigravity-pkgs.default
      codex
      gemini-cli
      claude-code
      opencode
    ];

    fonts = with pkgs; [
      noto-fonts
      noto-fonts-cjk-sans
      noto-fonts-color-emoji
      dejavu_fonts
    ];
  };
in {
  # Toggle whole groups by commenting out the line below.
  environment.systemPackages =
    packages.core
    ++ packages.gnome
    ++ packages.wayland
    ++ packages.qtTheming
    ++ packages.media
    ++ packages.terminalRec
    ++ packages.productivity
    ++ packages.graphics
    ++ packages.dev
    ++ packages.db
    ++ packages.nixTools
    ++ packages.containers
    ++ packages.network
    ++ packages.monitoring
    ++ packages.hardware
    ++ packages.inputDebug
    ++ packages.security
    ++ packages.ai;

  environment.sessionVariables = {
    RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
  };

  fonts = {
    enableDefaultPackages = true;
    packages = with pkgs;
      [
        fira-code
        fira-code-symbols
      ]
      ++ packages.fonts
      ++ builtins.filter lib.attrsets.isDerivation
      (builtins.attrValues pkgs.nerd-fonts);
  };

  programs = {
    seahorse.enable = true;
    tcpdump.enable = true;
    wireshark.enable = true;
    nix-index.enable = true;
    atop.enable = true;
    iftop.enable = true;
    iotop.enable = true;
  };
}
