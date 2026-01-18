{...}: {
  imports = [
    ../nix.nix
    ../boot.nix
    ../kernel.nix
    ../locale.nix
    ../network.nix
    ../network-wifi.nix
    ../security.nix
    ../sudo.nix
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

  programs.mtr.enable = true;
}
