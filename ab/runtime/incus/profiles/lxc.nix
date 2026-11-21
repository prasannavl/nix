{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    ./guest.nix
    (modulesPath + "/virtualisation/lxc-container.nix")
    (modulesPath + "/virtualisation/lxc-image-metadata.nix")
  ];

  boot = {
    isContainer = true;
    specialFileSystems = lib.mkForce {};
    enableContainers = false;
  };

  systemd.services = {
    nixos-lxc-boot-system-links = {
      description = "Restore NixOS runtime system links after container /run setup";
      restartIfChanged = false;
      stopIfChanged = false;
      wantedBy = ["sysinit.target"];
      before = [
        "nixos-lxc-boot-activation.service"
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
        system_config="$(${pkgs.gnused}/bin/sed -n 's/^systemConfig=//p' /sbin/init | ${pkgs.coreutils}/bin/head -n 1)"
        if [ -z "$system_config" ] || [ ! -e "$system_config" ]; then
          echo "Unable to resolve booted NixOS system from /sbin/init" >&2
          exit 1
        fi

        ${pkgs.coreutils}/bin/ln -sfn "$system_config" /run/current-system
        ${pkgs.coreutils}/bin/ln -sfn "$system_config" /run/booted-system
      '';
    };

    nixos-lxc-boot-activation = {
      description = "Replay NixOS activation after container /run setup";
      restartIfChanged = false;
      stopIfChanged = false;
      wantedBy = ["sysinit.target"];
      requires = ["nixos-lxc-boot-system-links.service"];
      before = [
        "sysinit.target"
        "systemd-tmpfiles-setup.service"
        "systemd-udev-trigger.service"
        "systemd-networkd.service"
        "nix-daemon.service"
      ];
      after = [
        "nixos-lxc-boot-system-links.service"
        "register-nix-paths.service"
      ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        system_config="$(${pkgs.coreutils}/bin/readlink -f /run/current-system || true)"
        if [ -z "$system_config" ] || [ ! -x "$system_config/activate" ]; then
          echo "Unable to resolve activatable NixOS system from /run/current-system" >&2
          exit 1
        fi

        export NIXOS_ACTION=boot
        "$system_config/activate"

        ${config.nix.package}/bin/nix-env -p /nix/var/nix/profiles/system --set "$system_config"
        ${pkgs.coreutils}/bin/ln -sfn "$system_config" /run/current-system
        ${pkgs.coreutils}/bin/ln -sfn "$system_config" /run/booted-system
      '';
    };
  };
}
