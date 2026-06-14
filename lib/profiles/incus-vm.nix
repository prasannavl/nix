{
  lib,
  pkgs,
  modulesPath,
  hostName,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/incus-virtual-machine.nix")
    ../openssh.nix
    ../options.nix
    ../services/fail2ban-helper
    ../nix.nix
    ../systemd.nix
    ../security.nix
    ../sudo.nix
    ../nix-ld.nix
    ../users.nix
    ../sysctl-inotify.nix
    ../sysctl-vm.nix
    ../hardware.nix
  ];

  systemd = {
    network = {
      enable = true;
      wait-online.extraArgs = [
        "--interface=eth0:routable"
      ];
      networks."10-eth0" = {
        matchConfig.Name = "eth0";
        DHCP = "yes";
        dhcpV4Config.UseHostname = false;
        dhcpV6Config.UseHostname = false;
        networkConfig.IPv6AcceptRA = true;
      };
    };
  };

  documentation.enable = false;
  networking = {
    hostName = hostName;
    useNetworkd = true;
    useHostResolvConf = false;
    networkmanager.enable = false;
    useDHCP = false;
    firewall = {
      enable = true;
      allowedTCPPorts = [];
      allowedUDPPorts = [];
    };
    nftables.enable = true;
  };
  time.timeZone = "Asia/Singapore";
  i18n.defaultLocale = "en_US.UTF-8";

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
    resolved.enable = true;
  };

  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "hello";
      text = "echo hello world!";
    })
  ];

  virtualisation.incus.agent.enable = lib.mkDefault true;
}
