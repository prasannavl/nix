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
    (modulesPath + "/virtualisation/lxc-container.nix")
    (modulesPath + "/virtualisation/lxc-image-metadata.nix")
    ../openssh.nix
    ../options.nix
    ../services/machine-id
    ../services/migration-manager
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

  # Keep this profile as a thin Incus integration layer over upstream
  # virtualisation/lxc-container.nix. Do not replace upstream LXC boot,
  # activation, or store-registration behavior here.
  boot = {
    # This host is designed to run as a container image (shared kernel).
    isContainer = true;

    # Generic NixOS special filesystems are API/runtime mounts in Incus LXC:
    # Incus/LXC creates the container's minimal tmpfs /dev and procfs /proc,
    # while container systemd creates the tmpfs /run before normal units start.
    # Unprivileged guests cannot reliably remount these, so treat the full
    # attrset as runtime-owned instead of carrying a partial denylist.
    specialFileSystems = lib.mkForce {};

    enableContainers = false;
  };

  systemd = {
    # NixOS stage-2 creates these links before handing off to systemd, but
    # Incus/LXC can replace the early /run with the final container tmpfs.
    # Restore the links in final /run before upstream sysinit units need them.
    services.nixos-container-runtime-system-links = {
      description = "Restore NixOS runtime system links after container /run setup";
      wantedBy = ["sysinit.target"];
      before = [
        "nixos-container-runtime-activation.service"
        "register-nix-paths.service"
        "systemd-tmpfiles-setup.service"
        "systemd-udev-trigger.service"
        "systemd-networkd.service"
      ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Stage-2 activation creates these links before execing systemd. In an
        # LXC container, systemd then establishes the runtime tmpfs for /run,
        # so restore the same invariant before upstream sysinit units consume it.
        system_config="$(${pkgs.gnused}/bin/sed -n 's/^systemConfig=//p' /sbin/init | ${pkgs.coreutils}/bin/head -n 1)"
        if [ -z "$system_config" ] || [ ! -e "$system_config" ]; then
          echo "Unable to resolve booted NixOS system from /sbin/init" >&2
          exit 1
        fi

        ${pkgs.coreutils}/bin/ln -sfn "$system_config" /run/current-system
        ${pkgs.coreutils}/bin/ln -sfn "$system_config" /run/booted-system
      '';
    };

    # Boot activation also writes runtime state under /run, such as agenix
    # secrets. Re-run the boot activation after final /run exists so services
    # see the same activation-owned state they would see on bare metal.
    services.nixos-container-runtime-activation = {
      description = "Replay NixOS activation after container /run setup";
      wantedBy = ["sysinit.target"];
      requires = ["nixos-container-runtime-system-links.service"];
      after = ["nixos-container-runtime-system-links.service"];
      before = [
        "sysinit.target"
        "register-nix-paths.service"
        "systemd-tmpfiles-setup.service"
        "systemd-udev-trigger.service"
        "systemd-networkd.service"
        "nix-daemon.service"
        "tailscaled.service"
      ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Stage-2 activation runs before container systemd establishes the
        # final /run tmpfs. Replay activation once after /run exists so
        # runtime activation products such as /run/agenix are present before
        # services consume them.
        system_config="$(${pkgs.coreutils}/bin/readlink -f /run/current-system || true)"
        if [ -z "$system_config" ] || [ ! -x "$system_config/activate" ]; then
          echo "Unable to resolve activatable NixOS system from /run/current-system" >&2
          exit 1
        fi

        export NIXOS_ACTION=boot
        "$system_config/activate"
      '';
    };

    tmpfiles.rules = [
      # The state disk is mounted from the host at 0750 for security; fix
      # the in-container /var/lib to the standard 0755 so non-root services
      # such as nixbot can traverse it.
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
        # Hostnames are declared through Nix; applying DHCP hostnames can
        # D-Bus-activate hostnamed during switch and race its socket restart
        # showing up as failed network online during systemd upgrade switch.
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

  # A simple marker package so we know this what we're in.
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "hello";
      text = "echo hello world!";
    })
  ];
}
