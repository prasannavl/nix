{
  inputs,
  config,
  lib,
  ...
}: let
  incusLib = import ../../lib/incus/lib.nix {
    inherit config lib;
  };
  incusSecrets = ../../data/secrets/globals/incus;
  fpp = incusLib.fabricPolicyProfiles;
  abirdTopology = {
    abird-platform = {
      network = {
        subnetOctet = 0;
        allow = [
          {
            to = {
              project = "default";
              address = "10.10.30.20";
            };
            tcp = [53];
            udp = [53];
          }
        ];
      };
      instances = {
        nest.octet = 10;
        ci.octet = 80;
      };
    };
    abird.network = {
      subnetOctet = 100;
      allow = [];
    };
    abird-dev.network = {
      subnetOctet = 220;
      allow = [];
    };
  };
  addressFor = stack: role: "10.10.${toString abirdTopology.${stack}.network.subnetOctet}.${toString abirdTopology.${stack}.instances.${role}.octet}";
  abirdNestAddress = addressFor "abird-platform" "nest";
  abirdCiAddress = addressFor "abird-platform" "ci";
  resolveAccess = from: rule:
    {
      from = from;
      to = rule.to.project;
      destination = rule.to.address;
    }
    // lib.optionalAttrs (rule ? tcp) {tcpPorts = rule.tcp;}
    // lib.optionalAttrs (rule ? udp) {udpPorts = rule.udp;};
  abirdForwardRules = builtins.concatLists (
    lib.mapAttrsToList (
      from: stack: map (resolveAccess from) stack.network.allow
    )
    abirdTopology
  );
  isolatedProjectConfig = {
    "features.images" = "true";
    "features.networks" = "false";
    "features.profiles" = "true";
    "features.storage.buckets" = "true";
    "features.storage.volumes" = "true";
  };
  projectNames = ["pvl" "abird-platform" "abird" "abird-dev"];
  projects = {
    pvl = {
      pool = "pvl";
      network = {
        policy = fpp.open;
        name = "ipvlbr0";
        ipv4Address = "10.10.50.1/24";
        dhcpRanges = "10.10.50.100-10.10.50.199";
      };
      config = {
        "restricted.containers.nesting" = "allow";
        "restricted.devices.proxy" = "allow";
      };
    };
    abird-platform = {
      pool = "abird-platform";
      network = {
        policy = fpp.containedPublic;
        name = "iabirdplatbr0";
        ipv4Address = "10.10.0.1/24";
        dhcpRanges = "10.10.0.100-10.10.0.199";
      };
      config = {
        "restricted.devices.disk" = "allow";
        "restricted.devices.disk.paths" = "/var/lib/incus-delegations/abird-platform,/var/lib/incus-delegations/abird,/var/lib/incus-delegations/abird-dev";
        "restricted.devices.proxy" = "allow";
      };
    };
    abird = {
      pool = "abird";
      network = {
        policy = fpp.containedPublic;
        name = "iabirdbr0";
        ipv4Address = "10.10.100.1/24";
        dhcpRanges = "10.10.100.100-10.10.100.199";
      };
      config = {};
    };
    abird-dev = {
      pool = "abird-dev";
      network = {
        policy = fpp.containedPublic;
        name = "iabirdbr2";
        ipv4Address = "10.10.220.1/24";
        dhcpRanges = "10.10.220.100-10.10.220.199";
      };
      config = {};
    };
  };
  fabricIsolation = incusLib.mkManagedFabricPolicy {
    defaultPolicy = fpp.open;
    forwardRules = abirdForwardRules;
    projects = projects;
  };
  mkBridgeNetwork = network: {
    config = {
      "ipv4.address" = network.ipv4Address;
      "ipv4.dhcp.ranges" = network.dhcpRanges;
      "ipv4.nat" = "true";
      "ipv6.address" = "auto";
    };
    description = "";
    name = network.name;
    type = "bridge";
    project = "default";
  };
  projectBridgeNetworks =
    builtins.map
    (project: mkBridgeNetwork projects.${project}.network)
    projectNames;
  mkStoragePool = name: {
    config = {
      source = "/var/lib/incus/storage-pools/${name}";
    };
    description = "";
    name = name;
    driver = "btrfs";
  };
  projectStoragePools = builtins.map (project: mkStoragePool projects.${project}.pool) projectNames;
  mkProjectProfile = project: let
    projectConfig = projects.${project};
  in {
    config = {};
    description = "";
    devices = {
      eth0 = {
        name = "eth0";
        network = projectConfig.network.name;
        type = "nic";
      };
      root = {
        path = "/";
        pool = projectConfig.pool;
        type = "disk";
      };
    };
    name = "default";
    project = project;
  };
  mkRestrictedProject = name: {
    name = name;
    description = "";
    config = mkRestrictedProjectConfig name;
  };
  mkRestrictedProjectConfig = name: let
    projectConfig = projects.${name};
  in
    isolatedProjectConfig
    // {
      restricted = "true";
      # Incus 7.0 only accepts security.syscalls.intercept.mount when restricted
      # projects use interception = allow. "full" is only for the more dangerous
      # mount.allowed / mount.shift path, which we do not use here.
      "restricted.containers.interception" = "allow";
      "restricted.containers.lowlevel" = "block";
      "restricted.containers.nesting" = "allow";
      "restricted.containers.privilege" = "unprivileged";
      "restricted.devices.disk" = "managed";
      "restricted.devices.gpu" = "allow";
      "restricted.devices.nic" = "managed";
      "restricted.devices.unix-char" = "allow";
      "restricted.networks.access" = projectConfig.network.name;
      "restricted.storage-pools.access" = projectConfig.pool;
    }
    // projectConfig.config;
  mkLxc = incusLib.mkLxc;
  amdGpuDevices = incusLib.mkGpuDevices {
    card = 1;
    render = 128;
    kfd = true;
  };
in {
  assertions = fabricIsolation.assertions;

  services = {
    incus-manager = {
      global = {
        startConcurrency = 2;

        certificates = [
          {
            name = "pvl";
            type = "client";
            restricted = false;
            projects = [];
            certificate = builtins.readFile (incusSecrets + "/pvl.crt");
          }
        ];

        certificateDelegations = {
          pvl = {
            project = "pvl";
          };
          abird-platform = {
            project = "abird-platform";
          };
          abird = {
            project = "abird";
          };
          abird-dev = {
            project = "abird-dev";
          };
        };
      };

      default = {
        routes = [
          {
            address = "10.10.30.0";
            prefixLength = 24;
            via = "10.10.20.20";
          }
        ];

        instances = {
          pvl-vlab = mkLxc {
            name = "pvl-vlab";
            ipv4Address = "10.10.20.10";
            startPriority = 20;
            removalPolicy = "delete-all";
            privileged = true;
            nestedContainers = true;
            extraDevices = amdGpuDevices;
          };

          pvl-vlab-1 = mkLxc {
            name = "pvl-vlab-1";
            ipv4Address = "10.10.20.30";
            startPriority = 20;
            removalPolicy = "delete-all";
            privileged = true;
            nestedContainers = true;
            extraDevices =
              {
                incus-api = incusLib.mkIncusProxy {
                  connectHost = "10.10.20.1";
                };
                delegated-certs = incusLib.mkCertDelegation "pvl";
              }
              // amdGpuDevices;
          };

          gap3-gondor = mkLxc {
            name = "gap3-gondor";
            recreateTag = "1";
            image = inputs.self.nixosImages.incus-lxc-base;
            ipv4Address = "10.10.20.20";
            startPriority = 10;
            removalPolicy = "delete-all";
            privileged = true;
            nestedContainers = true;
            extraDevices = amdGpuDevices;
          };
        };
      };

      abird-platform.instances = {
        abird-nest = mkLxc {
          name = "abird-nest";
          ipv4Address = abirdNestAddress;
          startPriority = 10;
          removalPolicy = "delete-all";
          nestedContainers = true;
          extraDevices = {
            incus-api = incusLib.mkIncusProxy {
              connectHost = "10.10.20.1";
            };
            delegated-platform-certs = incusLib.mkCertDelegation "abird-platform";
            delegated-abird-certs = incusLib.mkCertDelegation "abird";
            delegated-dev-certs = incusLib.mkCertDelegation "abird-dev";
          };
        };
      };

      abird.instances = {};
      abird-dev.instances = {};
    };
  };

  virtualisation.incus.preseed = {
    config = {
      "core.https_address" = "[::]:8443";
    };

    networks =
      [
        {
          config = {
            "ipv4.address" = "10.10.20.1/24";
            "ipv4.dhcp.ranges" = "10.10.20.100-10.10.20.199";
            "ipv4.nat" = "true";
            "ipv6.address" = "auto";
          };
          description = "";
          name = "incusbr0";
          type = "bridge";
          project = "default";
        }
      ]
      ++ projectBridgeNetworks;

    storage_pools =
      [
        {
          config = {
            source = "/var/lib/incus/storage-pools/default";
          };
          description = "";
          name = "default";
          driver = "btrfs";
        }
      ]
      ++ projectStoragePools;

    storage_volumes = [];

    profiles =
      [
        {
          config = {};
          description = "";
          devices = {
            eth0 = {
              name = "eth0";
              network = "incusbr0";
              type = "nic";
            };
            root = {
              path = "/";
              pool = "default";
              type = "disk";
            };
          };
          name = "default";
          project = "default";
        }
      ]
      ++ builtins.map mkProjectProfile projectNames;

    projects = builtins.map mkRestrictedProject projectNames;
    certificates = [];
    cluster = null;
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
  };
  networking = {
    nftables.tables = fabricIsolation.nftablesTable;
    firewall = {
      interfaces = fabricIsolation.firewallInterfaces;
      trustedInterfaces = fabricIsolation.trustedInterfaces;
    };
  };
}
