{
  fail2banModule ? null,
  hostAgentModule ? null,
  hostName,
  localeModule ? null,
  machineIdModule ? null,
  nixPolicyModule ? null,
  runtimeProfile,
  tailscaleClient ? {},
}: {
  lib,
  pkgs,
  ...
}: let
  optionalImport = value: lib.optional (value != null) value;
  tailscaleServices = tailscaleClient.services or {};
in {
  imports =
    [
      runtimeProfile
      ../security/openssh.nix
      ../options.nix
      ../systemd.nix
      ../security/default.nix
      ../security/sudo.nix
      ../nix/ld.nix
      ../users.nix
      ../kernel/sysctl/inotify.nix
      ../kernel/sysctl/vm.nix
      ../hardware/default.nix
    ]
    ++ optionalImport machineIdModule
    ++ optionalImport hostAgentModule
    ++ optionalImport fail2banModule
    ++ optionalImport nixPolicyModule
    ++ optionalImport localeModule;

  age.secrets = tailscaleClient.age.secrets or {};

  x.sshDefault = true;
  documentation.enable = false;

  networking = {
    inherit hostName;
    firewall = {
      enable = true;
      allowedTCPPorts = [];
      allowedUDPPorts = [];
    };
    nftables.enable = true;
  };

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

  services = {
    getty.autologinUser = null;
    "machine-id" = lib.optionalAttrs (machineIdModule != null) {
      enable = true;
      runtimeHostname.enable = true;
    };
    tailscale = tailscaleServices.tailscale or {};
  };

  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "hello";
      text = "echo hello world!";
    })
  ];
}
