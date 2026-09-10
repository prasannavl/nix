{pkgs}: let
  lib = pkgs.lib;
  incusLib = import ../lib.nix {inherit lib;};
  managedFabricPolicy = incusLib.mkManagedFabricPolicy {
    defaultFabric = {
      subnets = {
        ipv4 = "10.10.20.0/24";
        ipv6 = "fd42:20::/64";
      };
      masqueradeToUplink = {
        ipv4 = true;
        ipv6 = true;
      };
    };
    defaultPolicy = incusLib.fabricPolicyProfiles.containedPublic;
    projects = {
      app.network = {
        name = "appbr0";
        policy = incusLib.fabricPolicyProfiles.containedPublic;
        subnets = {
          ipv4 = "10.10.40.0/24";
          ipv6 = "fd42:40::/64";
        };
        masqueradeToUplink = {
          ipv4 = true;
          ipv6 = true;
        };
      };
      platform.network = {
        name = "platformbr0";
        policy = incusLib.fabricPolicyProfiles.containedPublic;
        subnets = {
          ipv4 = "10.10.0.0/24";
          ipv6 = "fd42:0::/64";
        };
        masqueradeToUplink = {
          ipv4 = true;
          ipv6 = true;
        };
      };
    };
    routedFabrics.prod = {
      parent = "default";
      subnets = {
        ipv4 = "10.10.30.0/24";
        ipv6 = "fd42:30::/64";
      };
      policy = incusLib.fabricPolicyProfiles.containedPublic;
      masqueradeToUplink = {
        ipv4 = true;
        ipv6 = true;
      };
    };
    forwardRules = [
      {
        from = "prod";
        to = "platform";
        source = "10.10.30.20";
        destination = "10.10.0.10";
        tcpPorts = [18444];
      }
    ];
    sourcePreservingPrefixes = {
      ipv4 = ["10.10.0.0/16"];
      ipv6 = ["fd42::/48"];
    };
  };
  managedFabricRules = managedFabricPolicy.nftablesTable.incusManagedFabricPolicy.content;
  managedFabricNatRules = managedFabricPolicy.nftablesTable.incusManagedFabricPolicyNat.content;
  invalidRoutedFabricPolicy = incusLib.mkManagedFabricPolicy {
    projects = {};
    routedFabrics.invalid = {
      parent = "missing";
      subnets.ipv4 = "10.10.40.0/24";
      policy = incusLib.fabricPolicyProfiles.containedPublic;
    };
  };
  invalidRoutedFabricShape = incusLib.mkManagedFabricPolicy {
    projects = {};
    routedFabrics.invalid = "not-an-attribute-set";
  };
  invalidRoutedFamilyPolicy = incusLib.mkManagedFabricPolicy {
    projects = {};
    routedFabrics.invalid = {
      parent = "default";
      subnets.ipv4 = "fd42:40::/64";
      masqueradeToUplink.ipv6 = true;
    };
  };
  invalidForwardFamilyPolicy = incusLib.mkManagedFabricPolicy {
    projects = {
      app.network = {
        name = "appbr0";
        policy = incusLib.fabricPolicyProfiles.containedPublic;
      };
    };
    forwardRules = [
      {
        from = "default";
        to = "app";
        source = "10.10.20.20";
        destination = "fd42:40::20";
        tcpPorts = [443];
      }
    ];
  };
  overlappingFabricPolicy = incusLib.mkManagedFabricPolicy {
    defaultFabric.subnets.ipv4 = "10.10.20.0/24";
    enabledFamilies = ["ipv4"];
    projects.app.network = {
      name = "appbr0";
      policy = incusLib.fabricPolicyProfiles.containedPublic;
      subnets.ipv4 = "10.10.20.128/25";
    };
  };
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
        virtualisation.incus.preseed = {
          config = {};
          networks = [];
          profiles = [];
          projects = [];
          storage_pools = [];
        };

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
            startConcurrency = 1;
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
              network = {
                ipv4 = {
                  address = "10.10.30.20";
                  routes = ["10.10.31.0/24"];
                  filtering = true;
                };
                ipv6 = {
                  address = "fd42:30::20";
                  routes = ["fd42:31::/64"];
                  filtering = true;
                };
              };
              startPriority = -10;
              config."security.nesting" = "true";
              limits = {
                cpu = {
                  count = 2;
                  priority = 4;
                };
                memory = {
                  max = "2GiB";
                  swap.enable = false;
                  oomScoreAdjustment = 250;
                };
                disk = {
                  priority = 4;
                  devices = {
                    root.read = "100MiB";
                    data.rw = "1000iops";
                  };
                };
                network.devices.eth0.rxtx = "250Mbit";
              };
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
  unlimitedConfig =
    (evalConfig.extendModules {
      modules = [
        {
          services.incus-manager.global.startConcurrency = lib.mkForce (-1);
        }
      ];
    }).config;
  changedLimitConfig =
    (evalConfig.extendModules {
      modules = [
        {
          services.incus-manager.default.instances.web.limits = {
            memory = {
              max = lib.mkForce "3GiB";
              swap = {
                enable = lib.mkForce true;
                max = "1GiB";
              };
            };
            network.devices.eth0 = {
              rxtx = lib.mkForce null;
              rx = "200Mbit";
              tx = "100Mbit";
            };
          };
        }
      ];
    }).config;
  changedNetworkConfig =
    (evalConfig.extendModules {
      modules = [
        {
          services.incus-manager.default.instances.web.network = {
            ipv4.routes = lib.mkForce ["10.10.32.0/24"];
            ipv6.filtering = lib.mkForce false;
          };
        }
      ];
    }).config;
  invalidNetworkConfig =
    (evalConfig.extendModules {
      modules = [
        {
          services.incus-manager.default.instances.web.network = {
            ipv4.routes = lib.mkForce ["fd42:31::/64"];
            ipv6.address = lib.mkForce "fd42:30::20/64";
          };
        }
      ];
    }).config;
  remoteEval = evalConfig.extendModules {
    modules = [
      {
        services.incus-manager.global = {
          hostSuspend.enable = lib.mkForce false;
          certificates = lib.mkForce [];
          certificateDelegations = lib.mkForce {};
          remote = {
            enable = true;
            name = "test-remote";
            address = "https://127.0.0.1:8443";
            clientCertificateFile = "/dev/null";
            clientKeyFile = "/dev/null";
            acceptCertificate = true;
            projects = {
              default.allowedSubnets = {
                ipv4 = "10.10.30.0/24";
                ipv6 = "fd42:30::/64";
              };
              lab.allowedSubnets.ipv4 = "10.10.40.0/24";
            };
          };
        };
        services.incus-manager.default.instances.web.devices.delegated.certDelegation =
          lib.mkForce null;
      }
    ];
  };
  remoteConfig = remoteEval.config;
  invalidRemoteIpv6Config =
    (remoteEval.extendModules {
      modules = [
        {
          services.incus-manager.global.remote.projects.default.allowedSubnets.ipv6 =
            lib.mkForce "fd42:31::/64";
        }
      ];
    }).config;
  relativeCpuConfig =
    (evalConfig.extendModules {
      modules = [
        {
          services.incus-manager.default.instances.web.limits.cpu.count = lib.mkForce "80%";
        }
      ];
    }).config;
  invalidRelativeCpuConfig =
    builtins.tryEval
    (evalConfig.extendModules {
      modules = [
        {
          services.incus-manager.default.instances.web.limits.cpu.count = lib.mkForce "101%";
        }
      ];
    }).config.environment.etc."incus-machines/web.json".text;
  invalidSwapConfig =
    (evalConfig.extendModules {
      modules = [
        {
          services.incus-manager.default.instances.web.limits.memory.swap.max = "1GiB";
        }
      ];
    }).config;
  invalidVmSwapConfig =
    (evalConfig.extendModules {
      modules = [
        {
          services.incus-manager.lab.instances.vm.limits.memory.swap.enable = false;
        }
      ];
    }).config;
  invalidCombinedDiskLimit =
    builtins.tryEval
    (evalConfig.extendModules {
      modules = [
        {
          services.incus-manager.default.instances.web.limits.disk.devices.root.read =
            lib.mkForce "100MiB,2000iops";
        }
      ];
    }).config.environment.etc."incus-machines/web.json".text;
  unsupportedDiskLimitConfig =
    (evalConfig.extendModules {
      modules = [
        {
          services.incus-manager.global.diskIoLimitsSupported = false;
        }
      ];
    }).config;
  failedAssertions = builtins.filter (assertion: ! assertion.assertion) config.assertions;
  invalidSwapAssertions = builtins.filter (assertion: ! assertion.assertion) invalidSwapConfig.assertions;
  invalidVmSwapAssertions = builtins.filter (assertion: ! assertion.assertion) invalidVmSwapConfig.assertions;
  invalidNetworkAssertions = builtins.filter (assertion: ! assertion.assertion) invalidNetworkConfig.assertions;
  remoteAssertions = builtins.filter (assertion: ! assertion.assertion) remoteConfig.assertions;
  invalidRemoteIpv6Assertions =
    builtins.filter (assertion: ! assertion.assertion) invalidRemoteIpv6Config.assertions;
  unsupportedDiskLimitAssertions =
    builtins.filter (assertion: ! assertion.assertion) unsupportedDiskLimitConfig.assertions;

  envHasPrefix = prefix: env:
    builtins.any (entry: lib.hasPrefix prefix entry) env;

  webState = builtins.fromJSON config.environment.etc."incus-machines/web.json".text;
  ignoredState = builtins.fromJSON config.environment.etc."incus-machines/ignored.json".text;
  vmState = builtins.fromJSON config.environment.etc."incus-machines/lab.vm.json".text;
  changedLimitWebState = builtins.fromJSON changedLimitConfig.environment.etc."incus-machines/web.json".text;
  changedNetworkWebState = builtins.fromJSON changedNetworkConfig.environment.etc."incus-machines/web.json".text;
  relativeCpuWebState = builtins.fromJSON relativeCpuConfig.environment.etc."incus-machines/web.json".text;
  webMeta = builtins.fromJSON webState.userMeta."user.nixos-meta";
  ignoredMeta = builtins.fromJSON ignoredState.userMeta."user.nixos-meta";
  vmMeta = builtins.fromJSON vmState.userMeta."user.nixos-meta";
  webUnit = config.systemd.services.incus-web;
  changedNetworkWebUnit = changedNetworkConfig.systemd.services.incus-web;
  ignoredUnit = config.systemd.services.incus-ignored;
  unlimitedWebUnit = unlimitedConfig.systemd.services.incus-web;
  vmUnit = config.systemd.services."incus-lab.vm";
  reconcilerUnit = config.systemd.services.incus-machines-reconciler;
  imagesUnit = config.systemd.services.incus-images;
  preseedUnit = config.systemd.services.incus-preseed;
  certificatesUnit = config.systemd.services.incus-machines-certificates;
  limitsUnit = config.systemd.services.incus-machines-limits;
  autoStartTarget = config.systemd.targets.incus-machines-autostart;
  autoStartGate0 = config.systemd.targets.incus-machines-autostart-gate-0;
  autoStartGate1 = config.systemd.targets.incus-machines-autostart-gate-1;
  autoStartSettle0 = config.systemd.services.incus-machines-autostart-settle-0;
  autoStartSettle1 = config.systemd.services.incus-machines-autostart-settle-1;
  delegationUnit = config.systemd.services.incus-cert-delegation-tenant;
in
  assert lib.all (assertion: assertion.assertion) managedFabricPolicy.assertions;
  assert lib.hasInfix ''iifname "incusbr0" ip saddr 10.10.30.0/24 oifname "platformbr0" ip saddr 10.10.30.20 ip daddr 10.10.0.10 tcp dport 18444 accept'' managedFabricRules;
  assert lib.hasInfix ''iifname "incusbr0" ip saddr 10.10.30.0/24 oifname "appbr0" drop comment "deny prod -> app"'' managedFabricRules;
  assert lib.hasInfix ''iifname "incusbr0" ip6 saddr fd42:30::/64 oifname "appbr0" drop comment "deny prod -> app"'' managedFabricRules;
  assert lib.hasInfix ''iifname "incusbr0" meta nfproto ipv4 ip saddr != 10.10.30.0/24'' managedFabricRules;
  assert lib.hasInfix ''iifname "incusbr0" meta nfproto ipv6 ip6 saddr != fd42:30::/64'' managedFabricRules;
  assert !lib.hasInfix ''meta nfproto ipv6 ip6 saddr != fd42:30::/64 meta nfproto ipv4 udp sport 68'' managedFabricRules;
  assert !lib.hasInfix ''meta nfproto ipv4 ip saddr != 10.10.30.0/24 meta nfproto ipv6 udp sport 546'' managedFabricRules;
  assert lib.hasInfix ''ip saddr 10.10.30.0/24 ip daddr != {'' managedFabricNatRules;
  assert lib.hasInfix ''ip6 saddr fd42:30::/64 ip6 daddr != {'' managedFabricNatRules;
  assert !lib.hasInfix ''oifname !='' managedFabricNatRules;
  assert lib.hasInfix ''masquerade comment "masquerade prod ipv4 across perimeter"'' managedFabricNatRules;
  assert lib.hasInfix ''masquerade comment "masquerade prod ipv6 across perimeter"'' managedFabricNatRules;
  assert lib.hasInfix ''iifname "appbr0" meta nfproto ipv6 meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, mld-listener-report, mld-listener-done, nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert, mld2-listener-report } accept comment "allow IPv6 router control from appbr0"'' managedFabricRules;
  assert lib.hasInfix ''oifname "appbr0" meta nfproto ipv6 meta l4proto ipv6-icmp icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, mld-listener-query, nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept comment "allow IPv6 router control to appbr0"'' managedFabricRules;
  assert lib.any (assertion: !assertion.assertion && lib.hasInfix "parent fabric" assertion.message) invalidRoutedFabricPolicy.assertions;
  assert lib.any (assertion: !assertion.assertion && lib.hasInfix "family-keyed subnets" assertion.message) invalidRoutedFabricShape.assertions;
  assert (builtins.tryEval (builtins.deepSeq invalidRoutedFabricShape.assertions true)).success;
  assert lib.any (assertion: !assertion.assertion && lib.hasInfix "family-keyed subnets" assertion.message) invalidRoutedFamilyPolicy.assertions;
  assert lib.any (assertion: !assertion.assertion && lib.hasInfix "forwardRules" assertion.message) invalidForwardFamilyPolicy.assertions;
  assert lib.any (assertion: !assertion.assertion && lib.hasInfix "must not overlap" assertion.message) overlappingFabricPolicy.assertions;
  assert failedAssertions == [];
  assert lib.any (
    assertion:
      assertion.assertion
      && lib.hasInfix "network and limit reconcilers" assertion.message
  )
  config.assertions;
  assert invalidCombinedDiskLimit.success == false;
  assert lib.any (assertion: lib.hasInfix "family-correct" assertion.message) invalidNetworkAssertions;
  assert remoteAssertions == [];
  assert lib.any (
    assertion:
      !assertion.assertion
      && lib.hasInfix "allowedSubnets" assertion.message
      && lib.hasInfix "ipv6" assertion.message
  )
  invalidRemoteIpv6Assertions;
  assert invalidRelativeCpuConfig.success == false;
  assert builtins.length unsupportedDiskLimitAssertions == 1;
  assert lib.hasInfix "disk limits are unsupported" (builtins.head unsupportedDiskLimitAssertions).message;
  assert unlimitedWebUnit.wantedBy == ["multi-user.target"];
  assert !(builtins.hasAttr "incus-machines-autostart" unlimitedConfig.systemd.targets);
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
  assert webState.networkDevices.eth0
  == {
    "ipv4.address" = "10.10.30.20";
    "ipv4.routes" = "10.10.31.0/24";
    "ipv6.address" = "fd42:30::20";
    "ipv6.routes" = "fd42:31::/64";
    "security.ipv4_filtering" = "true";
    "security.ipv6_filtering" = "true";
  };
  assert webMeta.network.deviceProperties.eth0
  == [
    "ipv4.address"
    "ipv4.routes"
    "ipv6.address"
    "ipv6.routes"
    "security.ipv4_filtering"
    "security.ipv6_filtering"
  ];
  assert ignoredState.networkDevices.eth0 == {"ipv4.address" = "10.10.30.21";};
  assert webState.limitConfig
  == {
    "limits.cpu" = "2";
    "limits.cpu.priority" = "4";
    "limits.disk.priority" = "4";
    "limits.memory" = "2GiB";
    "limits.memory.enforce" = "hard";
    "limits.memory.oom_priority" = "250";
    "limits.memory.swap" = "false";
  };
  assert webState.limitDevices.root."limits.read" == "100MiB";
  assert webState.limitDevices.data."limits.max" == "1000iops";
  assert webState.limitDevices.eth0."limits.max" == "250Mbit";
  assert changedLimitWebState.configHash == webState.configHash;
  assert changedNetworkWebState.configHash == webState.configHash;
  assert changedNetworkWebState.networkDevices.eth0."ipv4.routes" == "10.10.32.0/24";
  assert changedNetworkWebState.networkDevices.eth0."security.ipv6_filtering" == "false";
  assert changedLimitWebState.limitConfig."limits.memory" == "3GiB";
  assert relativeCpuWebState.limitConfig."limits.cpu" == "80%";
  assert relativeCpuWebState.cpuCapacity == null;
  assert relativeCpuWebState.configHash == webState.configHash;
  assert changedLimitWebState.limitConfig."limits.memory.swap" == "1GiB";
  assert changedLimitWebState.limitDevices.eth0."limits.ingress" == "200Mbit";
  assert changedLimitWebState.limitDevices.eth0."limits.egress" == "100Mbit";
  assert ignoredState.limitConfig == {};
  assert ignoredState.limitDevices == {};
  assert !(builtins.hasAttr "limits" ignoredMeta);
  assert builtins.any (assertion: lib.hasInfix "memory.swap.max requires" assertion.message) invalidSwapAssertions;
  assert builtins.any (assertion: lib.hasInfix "lab.vm.memory.swap" assertion.message) invalidVmSwapAssertions;
  assert webState.desiredDisks.data
  == {
    type = "disk";
    source = "/var/lib/incus-machines/managed-dirs/web-data";
    path = "/data";
    "limits.max" = "1000iops";
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
  assert webUnit.wantedBy == [];
  assert builtins.elem "incus-preseed.service" webUnit.after;
  assert builtins.elem "incus-images.service" webUnit.after;
  assert builtins.elem "network-online.target" webUnit.after;
  assert lib.hasSuffix " machine" webUnit.serviceConfig.ExecStart;
  assert lib.hasInfix " stop-instance web default" webUnit.serviceConfig.ExecStop;
  assert webUnit.restartIfChanged == true;
  assert builtins.length webUnit.restartTriggers == 2;
  assert changedNetworkWebUnit.restartTriggers == webUnit.restartTriggers;
  assert lib.any (trigger: lib.hasSuffix "/bin/incus-machines-helper" (toString trigger)) webUnit.restartTriggers;
  assert webUnit.stopIfChanged == true;
  assert ignoredUnit.wantedBy == [];
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
  assert builtins.elem "sysinit-reactivation.target" preseedUnit.wantedBy;
  assert preseedUnit.restartTriggers != [];
  assert preseedUnit.restartIfChanged == true;
  assert !(builtins.hasAttr "incus-machines-routes" config.systemd.services);
  assert certificatesUnit.wantedBy == ["sysinit-reactivation.target"];
  assert limitsUnit.wantedBy == ["sysinit-reactivation.target"];
  assert limitsUnit.restartTriggers != [];
  assert lib.hasSuffix " limits --all" limitsUnit.serviceConfig.ExecStart;
  assert lib.hasSuffix " certificates" certificatesUnit.serviceConfig.ExecStart;
  assert delegationUnit.wantedBy == ["sysinit-reactivation.target"];
  assert envHasPrefix "INCUS_MACHINES_CERTIFICATE_DELEGATION_NAME=tenant" delegationUnit.serviceConfig.Environment;
  assert envHasPrefix "INCUS_MACHINES_CERTIFICATE_DELEGATION_MAX_CERTIFICATES=4" delegationUnit.serviceConfig.Environment;
  assert builtins.elem "d /var/lib/incus-machines/managed-dirs/web-data 0755 root root -" config.systemd.tmpfiles.rules;
  assert builtins.elem "d /var/lib/incus-delegations/tenant - - - -" config.systemd.tmpfiles.rules;
  assert lib.hasInfix "incus-machines-host-suspend pre" config.powerManagement.powerDownCommands;
  assert lib.hasInfix "incus-machines-host-suspend post" config.powerManagement.resumeCommands;
  assert autoStartTarget.wantedBy == ["multi-user.target"];
  assert autoStartTarget.unitConfig.X-StopOnReconfiguration == true;
  assert builtins.elem "incus-web.service" autoStartTarget.wants;
  assert builtins.elem "incus-ignored.service" autoStartTarget.wants;
  assert autoStartGate0.unitConfig.X-StopOnReconfiguration == true;
  assert autoStartGate1.unitConfig.X-StopOnReconfiguration == true;
  assert autoStartGate0.before == ["incus-web.service"];
  assert autoStartGate1.after == ["incus-machines-autostart-settle-0.service"];
  assert autoStartGate1.before == ["incus-ignored.service"];
  assert autoStartSettle0.after == ["incus-web.service"];
  assert autoStartSettle0.before == ["incus-machines-autostart-gate-1.target"];
  assert lib.hasInfix "--machine web" autoStartSettle0.serviceConfig.ExecStart;
  assert autoStartSettle1.after == ["incus-ignored.service"];
  assert autoStartSettle1.before == [];
  assert lib.hasInfix "--machine ignored" autoStartSettle1.serviceConfig.ExecStart;
    pkgs.runCommand "incus-module-test" {} ''
      touch "$out"
    ''
