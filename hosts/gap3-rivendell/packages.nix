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
      nvtopPackages.full
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
    ++ packages.graphics
    ++ packages.misc;
}
