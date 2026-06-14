{pkgs, ...}: {
  imports = [
    ./all.nix
    ../../lib/incus
    ../../lib/swap-auto.nix
    ../../lib/profiles/all.nix
    ../../lib/podman.nix
  ];

  environment.systemPackages = with pkgs; [
    # Core
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
    dig
    sysstat
    helix

    # GNOME
    gnome-tweaks

    # Media
    vlc
    mpv
    pavucontrol
    alsa-utils
    restic
    btrfs-assistant

    # Wayland
    wl-clipboard-x11
    wl-mirror

    # Graphics
    mesa-demos
    libva-utils
    vulkan-tools

    # Development
    fish
    gdb
    vim.xxd

    # Database
    postgresql_18

    # Network
    iperf3
    cloudflared
    tailscale

    # Monitoring
    nethogs

    # Hardware
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

    # Security
    sbctl
    age
    git-credential-manager
    ente-auth
    openssl

    # Nix tools
    nvd

    # AI
    codex
    codex-wrapper
    opencode
  ];

  programs = {
    seahorse.enable = true;
    tcpdump.enable = true;
    atop.enable = true;
    iftop.enable = true;
    iotop.enable = true;
  };

  systemd.tmpfiles.rules = [
    "d /var/log/pvl 0755 pvl pvl -"
  ];
}
