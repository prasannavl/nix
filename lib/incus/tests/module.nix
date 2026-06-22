{pkgs}: let
  lib = pkgs.lib;
  fakeInputs.self.nixosImages = {
    incus-lxc-base = "images:debian/12";
    incus-vm-base = "images:ubuntu/24.04";
  };

  evalConfig = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    pkgs = pkgs;
    specialArgs.inputs = fakeInputs;
    modules = [
      ../default.nix
      {
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
        };
        networking.hostName = "incus-test";
        networking.nftables.enable = true;

        services.incus-manager = {
          global = {
            defaultLxcImage = "images:debian/12";
            defaultLxcImageAlias = "debian-12";
            defaultVmImage = "images:ubuntu/24.04";
            defaultVmImageAlias = "ubuntu-24-04";
            controllerId = "controller-a";
            imageTag = "image-1";
            bootTag = "boot-global";
            recreateTag = "recreate-global";
            autoReconcile = true;
            certificates = [
              {
                name = "ops";
                restricted = true;
                projects = ["default"];
                certificate = ''
                  -----BEGIN CERTIFICATE-----
                  fake
                  -----END CERTIFICATE-----
                '';
              }
            ];
            certificateDelegations.tenant = {
              project = "default";
              maxCertificates = 4;
            };
            hostSuspend = {
              enable = true;
              includeVirtualMachines = true;
              graceTimeoutSec = 9;
              forceTimeoutSec = 3;
            };
          };

          default.instances = {
            web = {
              ipv4Address = "10.10.30.20";
              config."security.nesting" = "true";
              bootTag = "boot-local";
              recreateTag = "recreate-local";
              devices = {
                data = {
                  source = "/var/lib/incus-machines/managed-dirs/web-data";
                  path = "/data";
                  removalPolicy = "delete";
                };
                delegated = {
                  type = "disk";
                  certDelegation = "tenant";
                };
              };
            };

            ignored = {
              ipv4Address = "10.10.30.21";
              reconcilePolicy = "ignore";
            };
          };

          lab.instances.vm = {
            kind = "vm";
            image = "images:ubuntu/24.04";
            imageAlias = "lab-vm-image";
            ipv4Address = "10.10.40.20";
            state = "stopped";
            autoStart = false;
            waitForSsh = false;
            hostSuspendPolicy = "ignore";
          };
        };
      }
    ];
  };

  config = evalConfig.config;
  failedAssertions = builtins.filter (assertion: ! assertion.assertion) config.assertions;

  envHasPrefix = prefix: env:
    builtins.any (entry: lib.hasPrefix prefix entry) env;

  webState = builtins.fromJSON config.environment.etc."incus-machines/web.json".text;
  ignoredState = builtins.fromJSON config.environment.etc."incus-machines/ignored.json".text;
  vmState = builtins.fromJSON config.environment.etc."incus-machines/lab.vm.json".text;
  webMeta = builtins.fromJSON webState.userMeta."user.nixos-meta";
  vmMeta = builtins.fromJSON vmState.userMeta."user.nixos-meta";
  webUnit = config.systemd.services.incus-web;
  ignoredUnit = config.systemd.services.incus-ignored;
  vmUnit = config.systemd.services."incus-lab.vm";
  reconcilerUnit = config.systemd.services.incus-machines-reconciler;
  imagesUnit = config.systemd.services.incus-images;
  certificatesUnit = config.systemd.services.incus-machines-certificates;
  delegationUnit = config.systemd.services.incus-cert-delegation-tenant;
in
  assert failedAssertions == [];
  assert config.virtualisation.incus.enable == true;
  assert config.virtualisation.incus.ui.enable == true;
  assert webState.name == "web";
  assert webState.kind == "lxc";
  assert webState.project == "default";
  assert webState.ipv4Address == "10.10.30.20";
  assert webState.imageTag == "image-1";
  assert webState.imageAlias == "debian-12";
  assert webState.state == "running";
  assert webState.reconcilePolicy == "auto";
  assert webState.bootTag == "boot-global:boot-local";
  assert webState.recreateTag == "recreate-global:recreate-local";
  assert webState.config."security.nesting" == "true";
  assert webState.desiredDisks.data
  == {
    type = "disk";
    source = "/var/lib/incus-machines/managed-dirs/web-data";
    path = "/data";
  };
  assert webState.desiredDisks.delegated
  == {
    type = "disk";
    source = "/var/lib/incus-delegations/tenant";
    path = "/var/lib/incus-delegation/tenant";
  };
  assert webState.desiredDiskGcMetadata.data.removalPolicy == "delete";
  assert webState.desiredDiskGcMetadata.data.source == "/var/lib/incus-machines/managed-dirs/web-data";
  assert webState.desiredDiskGcMetadata.delegated.certificateDelegation == true;
  assert webMeta.controller == "controller-a";
  assert webMeta.hostSuspendPolicy == "stop";
  assert ignoredState.reconcilePolicy == "ignore";
  assert ignoredState.autoStart == true;
  assert vmState.kind == "vm";
  assert vmState.project == "lab";
  assert vmState.name == "vm";
  assert vmState.imageAlias == "lab-vm-image";
  assert vmState.state == "stopped";
  assert vmState.autoStart == false;
  assert vmMeta.hostSuspendPolicy == "ignore";
  assert webUnit.wantedBy == ["multi-user.target"];
  assert builtins.elem "incus-preseed.service" webUnit.after;
  assert builtins.elem "incus-images.service" webUnit.after;
  assert builtins.elem "network-online.target" webUnit.after;
  assert lib.hasSuffix " machine" webUnit.serviceConfig.ExecStart;
  assert lib.hasInfix " stop-instance web default" webUnit.serviceConfig.ExecStop;
  assert webUnit.restartIfChanged == true;
  assert webUnit.stopIfChanged == true;
  assert ignoredUnit.wantedBy == ["multi-user.target"];
  assert lib.hasInfix " start-instance ignored default" ignoredUnit.serviceConfig.ExecStart;
  assert ignoredUnit.restartTriggers == [];
  assert ignoredUnit.restartIfChanged == false;
  assert ignoredUnit.stopIfChanged == false;
  assert vmUnit.wantedBy == [];
  assert lib.hasSuffix " machine" vmUnit.serviceConfig.ExecStart;
  assert reconcilerUnit.wantedBy == ["multi-user.target"];
  assert envHasPrefix "INCUS_MACHINES_RECONCILE_MODE=best-effort" reconcilerUnit.serviceConfig.Environment;
  assert envHasPrefix "INCUS_MACHINES_DECLARED_INSTANCES=" reconcilerUnit.serviceConfig.Environment;
  assert imagesUnit.wantedBy == ["sysinit-reactivation.target"];
  assert envHasPrefix "INCUS_MACHINES_IMAGE_TAG=image-1" imagesUnit.serviceConfig.Environment;
  assert certificatesUnit.wantedBy == ["sysinit-reactivation.target"];
  assert lib.hasSuffix " certificates" certificatesUnit.serviceConfig.ExecStart;
  assert delegationUnit.wantedBy == ["sysinit-reactivation.target"];
  assert envHasPrefix "INCUS_MACHINES_CERTIFICATE_DELEGATION_NAME=tenant" delegationUnit.serviceConfig.Environment;
  assert envHasPrefix "INCUS_MACHINES_CERTIFICATE_DELEGATION_MAX_CERTIFICATES=4" delegationUnit.serviceConfig.Environment;
  assert builtins.elem "d /var/lib/incus-machines/managed-dirs/web-data 0755 root root -" config.systemd.tmpfiles.rules;
  assert builtins.elem "d /var/lib/incus-delegations/tenant - - - -" config.systemd.tmpfiles.rules;
  assert lib.hasInfix "incus-machines-host-suspend pre" config.powerManagement.powerDownCommands;
  assert lib.hasInfix "incus-machines-host-suspend post" config.powerManagement.resumeCommands;
    pkgs.runCommand "incus-module-test" {} ''
      touch "$out"
    ''
