{
  inputs,
  config,
  lib,
  ...
}: let
  incusLib = import ../../lib/incus/lib.nix {
    inherit config lib;
  };
  isolatedProjectConfig = {
    "features.images" = "true";
    "features.networks" = "false";
    "features.profiles" = "true";
    "features.storage.buckets" = "true";
    "features.storage.volumes" = "true";
  };
  projectNames = ["pvl" "abird" "abird-stage" "abird-dev"];
  projects = {
    pvl = {
      pool = "pvl";
      network = {
        name = "ipvlbr0";
        ipv4Address = "10.10.50.1/24";
        dhcpRanges = "10.10.50.100-10.10.50.199";
      };
      config = {
        "restricted.containers.nesting" = "allow";
        "restricted.devices.proxy" = "allow";
      };
    };
    abird = {
      pool = "abird";
      network = {
        name = "iabirdbr0";
        ipv4Address = "10.10.100.1/24";
        dhcpRanges = "10.10.100.100-10.10.100.199";
      };
      config = {
        "restricted.containers.nesting" = "allow";
        "restricted.devices.disk" = "allow";
        "restricted.devices.disk.paths" = "/var/lib/incus-delegations/abird,/var/lib/incus-delegations/abird-stage,/var/lib/incus-delegations/abird-dev";
        "restricted.devices.proxy" = "allow";
      };
    };
    abird-stage = {
      pool = "abird-stage";
      network = {
        name = "iabirdbr1";
        ipv4Address = "10.10.200.1/24";
        dhcpRanges = "10.10.200.100-10.10.200.199";
      };
      config = {};
    };
    abird-dev = {
      pool = "abird-dev";
      network = {
        name = "iabirdbr2";
        ipv4Address = "10.10.220.1/24";
        dhcpRanges = "10.10.220.100-10.10.220.199";
      };
      config = {};
    };
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
      "restricted.containers.interception" = "block";
      "restricted.containers.lowlevel" = "block";
      "restricted.containers.privilege" = "unprivileged";
      "restricted.devices.disk" = "managed";
      "restricted.devices.nic" = "managed";
      "restricted.networks.access" = projectConfig.network.name;
      "restricted.storage-pools.access" = projectConfig.pool;
    }
    // projectConfig.config;
  mkLxc = {
    name,
    ipv4Address,
    image ? null,
    removalPolicy ? "delete-all",
    recreateTag ? null,
    privileged ? false,
    nestedContainers ? false,
    interceptMounts ? false,
    extraConfig ? {},
    extraDevices ? {},
  }:
    {
      ipv4Address = ipv4Address;
      removalPolicy = removalPolicy;
      config =
        {
          "security.privileged" =
            if privileged
            then "true"
            else "false";
        }
        // lib.optionalAttrs nestedContainers {
          "security.nesting" = "true";
        }
        // lib.optionalAttrs interceptMounts {
          "security.syscalls.intercept.mount" = "true";
          "security.syscalls.intercept.mount.shift" = "true";
        }
        // extraConfig;
      devices =
        {
          state = {
            source = name;
            path = "/var/lib";
            removalPolicy = "keep";
          };
        }
        // extraDevices;
    }
    // lib.optionalAttrs (image != null) {
      image = image;
    }
    // lib.optionalAttrs (recreateTag != null) {
      recreateTag = recreateTag;
    };
  amdGpuDevices = incusLib.mkGpuDevices {
    card = 1;
    render = 128;
    kfd = true;
  };
in {
  services = {
    incusMachines = {
      global = {
        certificates = [
          {
            name = "pvl";
            type = "client";
            restricted = false;
            projects = [];
            certificate = builtins.readFile ../../data/secrets/incus/pvl.crt;
          }
        ];

        certificateDelegations = {
          pvl = {
            project = "pvl";
          };
          abird = {
            project = "abird";
          };
          abird-stage = {
            project = "abird-stage";
          };
          abird-dev = {
            project = "abird-dev";
          };
        };
      };

      default.instances = {
        pvl-vlab = mkLxc {
          name = "pvl-vlab";
          ipv4Address = "10.10.20.10";
          privileged = true;
          nestedContainers = true;
          extraDevices = amdGpuDevices;
        };

        pvl-vlab-1 = mkLxc {
          name = "pvl-vlab-1";
          ipv4Address = "10.10.20.30";
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
          image = inputs.self.nixosImages.gap3-base;
          ipv4Address = "10.10.20.20";
          recreateTag = "3";
          privileged = true;
          nestedContainers = true;
          interceptMounts = true;
          extraDevices = amdGpuDevices;
        };
      };

      abird.instances = {
        abird-nest = mkLxc {
          name = "abird-nest";
          ipv4Address = "10.10.100.10";
          recreateTag = "1";
          nestedContainers = true;
          extraDevices = {
            incus-api = incusLib.mkIncusProxy {
              connectHost = "10.10.20.1";
            };
            delegated-certs = incusLib.mkCertDelegation "abird";
            delegated-stage-certs = incusLib.mkCertDelegation "abird-stage";
            delegated-dev-certs = incusLib.mkCertDelegation "abird-dev";
          };
        };
      };
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
  networking.firewall.trustedInterfaces =
    ["incusbr0"]
    ++ builtins.map (project: projects.${project}.network.name) projectNames;
}
