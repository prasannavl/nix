{
  hostName,
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
  imports = [
    ../../lib/profiles/systemd-container.nix
    (import ../../lib/incus-vm.nix {inherit hostName;})
    (import ../../users/pvl).systemd-container
  ];

  environment.systemPackages =
    packages.core
    ++ packages.network
    ++ packages.misc;
}
