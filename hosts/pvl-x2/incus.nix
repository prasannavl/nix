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
  abirdFabric = import ../../lib/flake/fabric-projection.nix {
    inherit lib;
    projection = import ./abird-fabric.nix;
  };
  defaultPrefixes = {
    ipv4 = "10.10.20.0/24";
    ipv6 = "fd42:36e5:81cf:b409::/64";
  };
  pvlPrefixes = {
    ipv4 = "10.10.50.0/24";
    ipv6 = "fd42:8f14:377a:bdd3::/64";
  };
  gondorPrefixes = abirdFabric.prefixes.abird-gondor;
  abirdBridgeNames = {
    abird-platform = "iabirdplatbr0";
    abird = "iabirdbr0";
    abird-dev = "iabirdbr2";
  };
  abirdFabricNames = builtins.attrNames abirdBridgeNames;
  physicalAbirdFabricNames = builtins.attrNames (abirdBridgeNames // {abird-gondor = null;});
  projectNames = ["pvl"] ++ abirdFabricNames;
  bridgeAddressFor = fabric: family: "${abirdFabric.addressForId fabric family 1}/${toString abirdFabric.prefixLength.${family}}";
  bridgeRangeFor = fabric: family: "${abirdFabric.addressForId fabric family 100}-${abirdFabric.addressForId fabric family 199}";
  staticNetwork = addresses: routes: {
    device = "eth0";
    ipv4 = {
      address = addresses.ipv4;
      routes = routes.ipv4 or [];
      filtering = true;
    };
    ipv6 = {
      address = addresses.ipv6;
      routes = routes.ipv6 or [];
      filtering = true;
    };
  };
  defaultAddress = addressId: {
    ipv4 = "10.10.20.${toString addressId}";
    ipv6 = "fd42:36e5:81cf:b409::${toString addressId}";
  };
  mkAbirdProject = fabric: {
    pool = fabric;
    network = {
      policy = fpp.containedPublic;
      name = abirdBridgeNames.${fabric};
      subnets = abirdFabric.prefixes.${fabric};
      masqueradeToUplink = {
        ipv4 = true;
        ipv6 = true;
      };
      ipv4Address = bridgeAddressFor fabric "ipv4";
      ipv4DhcpRanges = bridgeRangeFor fabric "ipv4";
      ipv6Address = bridgeAddressFor fabric "ipv6";
      ipv6DhcpRanges = bridgeRangeFor fabric "ipv6";
    };
    config = {};
  };
  abirdProjects = builtins.listToAttrs (
    map (fabric: lib.nameValuePair fabric (mkAbirdProject fabric)) abirdFabricNames
  );
  isolatedProjectConfig = {
    "features.images" = "true";
    "features.networks" = "false";
    "features.profiles" = "true";
    "features.storage.buckets" = "true";
    "features.storage.volumes" = "true";
  };
  projects =
    abirdProjects
    // {
      pvl = {
        pool = "pvl";
        network = {
          policy = fpp.open;
          name = "ipvlbr0";
          subnets = pvlPrefixes;
          masqueradeToUplink = {
            ipv4 = true;
            ipv6 = true;
          };
          ipv4Address = "10.10.50.1/24";
          ipv4DhcpRanges = "10.10.50.100-10.10.50.199";
          ipv6Address = "fd42:8f14:377a:bdd3::1/64";
          ipv6DhcpRanges = "fd42:8f14:377a:bdd3::100-fd42:8f14:377a:bdd3::199";
        };
        config = {
          "restricted.containers.nesting" = "allow";
          "restricted.devices.proxy" = "allow";
        };
      };
      abird-platform =
        abirdProjects.abird-platform
        // {
          config = {
            "restricted.devices.disk" = "allow";
            "restricted.devices.disk.paths" = "/var/lib/incus-delegations/abird-platform,/var/lib/incus-delegations/abird,/var/lib/incus-delegations/abird-dev";
            "restricted.devices.proxy" = "allow";
          };
        };
      abird-dev =
        abirdProjects.abird-dev
        // {
          rootVolumeSize = "32GiB";
          storageVolumeSize = "32GiB";
          config = {
            "limits.containers" = "7";
            "limits.cpu" = "8";
            "limits.disk" = "512GiB";
            "limits.instances" = "7";
            "limits.memory" = "8GiB";
          };
        };
    };
  fabricIsolation = incusLib.mkManagedFabricPolicy {
    defaultFabric = {
      subnets = defaultPrefixes;
      masqueradeToUplink = {
        ipv4 = true;
        ipv6 = true;
      };
    };
    # Preserve existing default-project management reachability. Gondor is
    # classified first as its own contained routed child in both families.
    defaultPolicy = fpp.open;
    enabledFamilies = abirdFabric.enabledFamilies;
    forwardRules = abirdFabric.forwardRules;
    projects = projects;
    routedFabrics.abird-gondor = {
      parent = "default";
      subnets = gondorPrefixes;
      policy = projects.abird.network.policy;
      masqueradeToUplink = {
        ipv4 = true;
        ipv6 = true;
      };
    };
  };
  mkBridgeNetwork = network: {
    config = {
      "ipv4.address" = network.ipv4Address;
      "ipv4.dhcp.ranges" = network.ipv4DhcpRanges;
      "ipv4.nat" = "false";
      "ipv6.address" = network.ipv6Address;
      "ipv6.dhcp.ranges" = network.ipv6DhcpRanges;
      "ipv6.dhcp.stateful" = "true";
      "ipv6.nat" = "false";
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
  mkStoragePool = project: let
    projectConfig = projects.${project};
    name = projectConfig.pool;
  in {
    config =
      {
        source = "/var/lib/incus/storage-pools/${name}";
      }
      // lib.optionalAttrs (projectConfig ? storageVolumeSize) {
        "volume.size" = projectConfig.storageVolumeSize;
      };
    description = "";
    name = name;
    driver = "btrfs";
  };
  projectStoragePools = map mkStoragePool projectNames;
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
      root =
        {
          path = "/";
          pool = projectConfig.pool;
          type = "disk";
        }
        // lib.optionalAttrs (projectConfig ? rootVolumeSize) {
          size = projectConfig.rootVolumeSize;
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
  assertions =
    fabricIsolation.assertions
    ++ abirdFabric.assertions
    ++ [
      {
        assertion = abirdFabric.enabledFamilies == ["ipv4" "ipv6"];
        message = "Pvl requires the local Abird projection to remain dual-stack";
      }
      {
        assertion = abirdFabric.fabricNames == physicalAbirdFabricNames;
        message = "Pvl requires the local Abird projection to match its physical fabrics";
      }
    ];

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
        instances = {
          pvl-vlab = mkLxc {
            name = "pvl-vlab";
            network = staticNetwork (defaultAddress 10) {};
            startPriority = 20;
            removalPolicy = "delete-all";
            privileged = true;
            nestedContainers = true;
            extraDevices = amdGpuDevices;
          };

          pvl-vlab-1 = mkLxc {
            name = "pvl-vlab-1";
            network = staticNetwork (defaultAddress 30) {};
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
            network = staticNetwork (defaultAddress 20) {
              ipv4 = [gondorPrefixes.ipv4];
              ipv6 = [gondorPrefixes.ipv6];
            };
            startPriority = 10;
            removalPolicy = "delete-all";
            privileged = true;
            nestedContainers = true;
            limits = {
              cpu = {
                count = 22;
                priority = 7;
              };
              memory = {
                max = "50GiB";
                oomScoreAdjustment = -250;
              };
              disk = {
                priority = 7;
                devices = {
                  root = {
                    read = "1GiB";
                    write = "500MiB";
                  };
                  state = {
                    read = "1GiB";
                    write = "500MiB";
                  };
                };
              };
              network.devices.eth0.rxtx = "600Mbit";
            };
            extraDevices = amdGpuDevices;
          };
        };
      };

      abird-platform.instances = {
        abird-nest = mkLxc {
          name = "abird-nest";
          network = staticNetwork (abirdFabric.addressesFor "abird-platform" "nest") {};
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
            "ipv4.nat" = "false";
            "ipv6.address" = "fd42:36e5:81cf:b409::1/64";
            "ipv6.dhcp.ranges" = "fd42:36e5:81cf:b409::100-fd42:36e5:81cf:b409::199";
            "ipv6.dhcp.stateful" = "true";
            "ipv6.nat" = "false";
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
    "net.ipv6.conf.all.forwarding" = 1;
  };
  networking = {
    nftables.tables = fabricIsolation.nftablesTable;
    firewall = {
      interfaces = fabricIsolation.firewallInterfaces;
      trustedInterfaces = fabricIsolation.trustedInterfaces;
    };
  };
}
