{
  config,
  pkgs,
  ...
}: let
  packages = {
    core = with pkgs; [
      wget
      curl
      fd
      ripgrep
      jq
      tree
      tmux
      git
      htop
      nvtopPackages.full
    ];

    network = with pkgs; [
      iperf3
      cloudflared
      tailscale
    ];

    graphics = with pkgs; [
      mesa-demos
      libva-utils
      vulkan-tools
    ];

    misc = with pkgs; [
      pciutils
      usbutils
    ];
  };
in {
  environment.systemPackages =
    packages.core
    ++ packages.network
    ++ packages.graphics
    ++ packages.misc;
}
