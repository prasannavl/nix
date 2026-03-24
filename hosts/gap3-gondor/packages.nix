{pkgs, ...}: let
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
    ];

    network = with pkgs; [
      iperf3
      tailscale
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
    ++ packages.misc;
}
