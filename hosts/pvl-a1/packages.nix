{
  lib,
  pkgs,
  inputs,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  antigravity-pkgs = inputs.antigravity.packages.${system};
in {
  environment.systemPackages = with pkgs; [
    # Core
    perf

    # GNOME
    gnome-control-center
    gnome-power-manager
    dconf-editor

    # Wayland
    wl-color-picker
    wayscriber
    unstable.wooz
    unstable.chameleos
    showmethekey
    flameshot

    # Media
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

    # Terminal recording
    asciinema
    asciinema-agg
    figlet
    lolcat
    ascii
    asciigraph

    # Productivity
    google-chrome
    thunderbird
    geary
    obsidian
    libreoffice
    xournalpp
    inkscape
    gimp
    imagemagick
    qbittorrent
    backrest

    # Graphics
    gtk4

    # Development
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
    yarn
    zed-wrapped
    nixd
    alejandra
    shellcheck
    patchelf
    fzf
    zathura
    imv
    kitty
    deno
    awscli2
    kubectl
    helm
    opentofu
    k9s

    # Database
    sqlite
    sqlitebrowser
    sqlitestudio
    sqlitestudio-plugins
    pgsql-tools
    pgadmin4-desktopmode
    nats-server
    natscli
    nkeys
    nsc
    # nats-top

    # Nix tools
    nix-index
    hydra-check
    cachix

    # Containers
    podman-compose
    distrobox
    crun
    runc
    nixos-container

    # Network
    networkmanagerapplet
    opensnitch
    opensnitch-ui

    # Monitoring
    wavemon

    # Input debugging
    xev
    xeyes
    xprop
    xset
    v4l-utils
    evtest
    wev

    # Security
    git-secrets
    git-crypt

    # AI
    jan
    gemini-cli
    claude-code

    # Custom packages
    (python3.withPackages (ps: with ps; [pip setuptools virtualenv numpy]))
    (google-cloud-sdk.withExtraComponents (with google-cloud-sdk.components; [
      log-streaming
    ]))
    antigravity-pkgs.default
  ];

  environment.sessionVariables = {
    RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
  };

  fonts = {
    enableDefaultPackages = true;
    packages = with pkgs;
      [
        fira-code
        fira-code-symbols
        noto-fonts
        noto-fonts-cjk-sans
        noto-fonts-color-emoji
        dejavu_fonts
      ]
      ++ builtins.filter lib.attrsets.isDerivation
      (builtins.attrValues pkgs.nerd-fonts);
  };

  programs = {
    wireshark.enable = true;
    nix-index.enable = true;
  };
}
