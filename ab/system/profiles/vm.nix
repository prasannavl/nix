{
  hostAgentModule ? null,
  localeModule ? null,
  networkPolicyModule ? null,
  nixPolicyModule ? null,
}: {
  lib,
  pkgs,
  ...
}: let
  optionalImport = value: lib.optional (value != null) value;
in {
  imports =
    [
      ../security/openssh.nix
      ../options.nix
      ../boot/default.nix
      ../kernel/default.nix
      ../security/default.nix
      ../security/sudo.nix
      ../systemd.nix
      ../kernel/sysctl/inotify.nix
      ../kernel/sysctl/coredump.nix
      ../kernel/sysctl/panic.nix
      ../kernel/sysctl/sysrq.nix
      ../kernel/sysctl/vm.nix
      ../users.nix
      ../hardware/default.nix
      ../nix/ld.nix
    ]
    ++ optionalImport nixPolicyModule
    ++ optionalImport localeModule
    ++ optionalImport networkPolicyModule
    ++ optionalImport hostAgentModule;

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

  environment.systemPackages = [pkgs.ethtool];
}
