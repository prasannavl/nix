{
  lib,
  pkgs,
  modulesPath,
  hostName,
  ...
}: {
  imports = [
    (modulesPath + "/virtualisation/lxc-container.nix")
    (modulesPath + "/virtualisation/lxc-image-metadata.nix")
    ../openssh.nix
    ../options.nix
    ../nix.nix
    ../systemd.nix
    ../security.nix
    ../sudo.nix
    ../nixbot
    ../nix-ld.nix
    ../users.nix
  ];

  boot = {
    # This host is designed to run as a container image (shared kernel).
    isContainer = true;

    # Incus/LXC owns these mounts for unprivileged guests. NixOS activation
    # otherwise tries to remount them and fails with fsconfig(2) denied/missing.
    specialFileSystems =
      lib.genAttrs [
        "/dev"
        "/dev/pts"
        "/dev/shm"
        "/proc"
        "/run"
        "/run/keys"
      ] (_: {
        enable = lib.mkForce false;
      });

    # Image-specific trim for container builds.
    enableContainers = false;
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
  systemd = {
    # Container images boot from the system profile, but many generated units
    # execute binaries through /run/current-system. Create that first-boot link
    # before udev/networkd start so the container can coldplug devices and bring
    # up networking before the first deploy switch.
    tmpfiles.rules = [
      "L+ /run/current-system - - - - /nix/var/nix/profiles/system"
    ];

    # The LXC image metadata injects a /run drop-in for udev coldplug that uses
    # /run/current-system. Create that link before udev-trigger, because tmpfiles
    # normally runs after the trigger and is too late for first-boot networking.
    services.nixos-current-system-link = {
      description = "Create /run/current-system for container first boot";
      wantedBy = ["sysinit.target"];
      before = [
        "systemd-udev-trigger.service"
        "systemd-networkd.service"
        "systemd-tmpfiles-setup.service"
      ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.coreutils}/bin/ln -sfn /nix/var/nix/profiles/system /run/current-system";
      };
    };

    # NixOS container images start systemd directly, so they do not get the
    # normal stage-2 activation path that materializes runtime state like
    # /run/agenix. Run activation once early after /run/current-system exists.
    services.nixos-container-activation = {
      description = "Run NixOS activation for container boot";
      wantedBy = ["sysinit.target"];
      after = ["nixos-current-system-link.service"];
      before = [
        "systemd-udev-trigger.service"
        "systemd-networkd.service"
        "systemd-tmpfiles-setup.service"
      ];
      unitConfig = {
        ConditionPathExists = "/run/current-system/activate";
        DefaultDependencies = false;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Environment = "NIXOS_ACTION=boot";
        ExecStart = "/run/current-system/activate";
      };
    };

    network = {
      enable = true;
      wait-online.extraArgs = [
        "--interface=eth0:routable"
      ];
      networks."10-eth0" = {
        matchConfig.Name = "eth0";
        DHCP = "yes";
        # Hostnames are declared through Nix; applying DHCP hostnames can
        # D-Bus-activate hostnamed during switch and race its socket restart
        # showing up as failed network online during systemd upgrade switch.
        dhcpV4Config.UseHostname = false;
        dhcpV6Config.UseHostname = false;
        networkConfig.IPv6AcceptRA = true;
      };
    };
  };

  services = {
    getty.autologinUser = null;
    resolved.enable = true;
    fail2ban.enable = true;
  };

  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "hello";
      text = "echo hello world!";
    })
  ];
}
