{pkgs, ...}: {
  imports = [
    ../../ab/system/options.nix
    ./policy/nix.nix
    ../../ab/system/boot/default.nix
    ../../ab/system/kernel/default.nix
    ./policy/locale.nix
    ./policy/network.nix
    ../../ab/system/network/wifi.nix
    ../../ab/system/security/default.nix
    ./policy/sudo.nix
    ./policy/systemd.nix
    ../../ab/system/kernel/sysctl/inotify.nix
    ../../ab/system/kernel/sysctl/coredump.nix
    ../../ab/system/kernel/sysctl/panic.nix
    ../../ab/system/kernel/sysctl/sysrq.nix
    ../../ab/system/kernel/sysctl/vm.nix
    ../../ab/system/users.nix
    ./policy/hardware.nix
    ../../ab/system/nix/ld.nix
    ../../ab/system/profiles/neovim.nix
  ];

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
    ssh-import-id
    powertop
    pciutils
    usbutils
    ethtool
  ];
}
