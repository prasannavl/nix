{
  config,
  lib,
  pkgs,
  modulesPath,
  hostName,
  ...
}: let
  tailscale = import ../services/tunnels/tailscale.nix {lib = lib;};
  tailscaleClient = tailscale.mkOptionalAuthKeyClient {
    config = config;
    keyName = hostName;
    secretsDir = ../../data/secrets/globals/tailscale;
    authKeyStoreName = "tailscale-${hostName}-auth-key.age";
    port = 0;
    advertiseTags = ["tag:vm"];
  };
  tailscaleServices = tailscaleClient.services or {};
in {
  imports = [
    (modulesPath + "/virtualisation/incus-virtual-machine.nix")
    ../openssh.nix
    ../options.nix
    ../services/machine-id
    ../nix.nix
    ../systemd.nix
    ../security.nix
    ../sudo.nix
    ../services/migration-manager
    ../services/fail2ban-helper
    ../nix-ld.nix
    ../users.nix
    ../sysctl-inotify.nix
    ../sysctl-vm.nix
    ../hardware.nix
  ];

  systemd = {
    tmpfiles.rules = [
      # The state disk is mounted from the host at 0750 for security; fix
      # the in-guest /var/lib to the standard 0755 so non-root services such as
      # nixbot can traverse it.
      "d /var/lib 0755 root root -"
    ];

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

  age.secrets = tailscaleClient.age.secrets or {};

  x.sshDefault = true;

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
    "machine-id" = {
      enable = true;
      runtimeHostname.enable = true;
    };
    resolved.enable = true;
    tailscale = tailscaleServices.tailscale or {};
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
