{pkgs, ...}: {
  imports = [
    ../openssh.nix
    ../options.nix
    ../nix.nix
    ../boot.nix
    ../kernel.nix
    ../locale.nix
    ../network.nix
    ../security.nix
    ../sudo.nix
    ../services/migration-manager
    ../systemd.nix
    ../sysctl-inotify.nix
    ../sysctl-kernel-coredump.nix
    ../sysctl-kernel-panic.nix
    ../sysctl-kernel-sysrq.nix
    ../sysctl-vm.nix
    ../users.nix
    ../hardware.nix
    ../nix-ld.nix
  ];

  x.sshDefault = true;

  programs = {
    bash = {
      enable = true;
      completion.enable = true;
    };
    htop.enable = true;
    mtr.enable = true;
    git.enable = true;
    tmux.enable = true;
  };

  environment.systemPackages = with pkgs; [
    ethtool
  ];
}
