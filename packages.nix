{
  config,
  pkgs,
  inputs,
  ...
}: let
  llm-agent-pkgs = inputs.llm-agents.packages.${pkgs.stdenv.hostPlatform.system};
  antigravity-pkgs = inputs.antigravity.packages.${pkgs.stdenv.hostPlatform.system};
  codex-pkgs = inputs.codex.packages.${pkgs.stdenv.hostPlatform.system};
in {
  environment.systemPackages = with pkgs; [
    vim
    tmux
    wget
    htop
    curl
    bash-completion
    fd
    ripgrep
    pciutils
    wdisplays
    iperf3
    jq
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
    nvtopPackages.full
    git
    tree
    lazygit
    python3
    nvd
    nix-index
    dconf-editor
    google-chrome
    ddcutil
    obsidian
    zed-editor
    solaar
    gnome-power-manager
    dmidecode
    powertop
    brightnessctl
    ghostty
    ente-auth
    ranger
    imagemagick
    cheese
    git-credential-manager

    distrobox
    e2fsprogs
    libreoffice
    xournalpp
    inkscape
    gimp
    logitech-udev-rules
    hydra-check
    cachix

    xdg-utils
    xdg-user-dirs
    gnome-control-center
    smartmontools
    nvme-cli

    xorg.xev
    xorg.xeyes
    xprop
    xset
    v4l-utils
    evtest

    mesa-demos
    libva-utils
    vulkan-tools
    crun
    runc
    gnumake
    lm_sensors

    llm-agent-pkgs.kilocode-cli
    antigravity-pkgs.default
    codex-pkgs.default
    jan

    rustup
    cargo
    rustc
    rustfmt
    rust-analyzer
    git-secrets
    git-crypt
    sops
    age
  ];

  fonts.packages = with pkgs; [
    noto-fonts
    dejavu_fonts
  ];
}
