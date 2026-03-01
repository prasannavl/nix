{pkgs, ...}: {
  imports = [
    ../options.nix
    ../nix.nix
    ../boot.nix
    ../kernel.nix
    ../locale.nix
    ../network.nix
    ../network-wifi.nix
    ../security.nix
    ../sudo.nix
    ../nixbot
    ../systemd.nix
    ../sysctl-inotify.nix
    ../sysctl-kernel-coredump.nix
    ../sysctl-kernel-panic.nix
    ../sysctl-kernel-sysrq.nix
    ../sysctl-vm.nix
    ../users.nix
    ../hardware.nix
    ../nix-ld.nix
    ../neovim.nix
  ];

  programs.bash = {
    enable = true;
    completion.enable = true;
  };
  programs.htop.enable = true;
  programs.mtr.enable = true;
  programs.git.enable = true;
  programs.tmux.enable = true;

  environment.systemPackages = with pkgs; [
    ssh-import-id
    powertop
    pciutils
    usbutils
    ethtool
  ];
}
