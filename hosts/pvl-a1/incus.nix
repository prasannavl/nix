{pkgs, ...}: let
  isolatedProjectConfig = {
    "features.images" = "true";
    "features.networks" = "false";
    "features.profiles" = "true";
    "features.storage.buckets" = "true";
    "features.storage.volumes" = "true";
  };
  mkRestrictedProject = name: network: {
    name = name;
    description = "";
    config =
      isolatedProjectConfig
      // {
        restricted = "true";
        "restricted.devices.nic" = "managed";
        "restricted.networks.access" = network;
      };
  };
in {
  virtualisation.incus = {
    enable = true;
    package = pkgs.incus;
    ui.enable = true;

    preseed = {
      config = {
        "core.https_address" = "[::]:8443";
      };

      networks = [
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
        {
          config = {
            "ipv4.address" = "10.10.23.1/24";
            "ipv4.dhcp.ranges" = "10.10.23.100-10.10.23.199";
            "ipv4.nat" = "true";
            "ipv6.address" = "auto";
          };
          description = "";
          name = "ipvlbr0";
          type = "bridge";
          project = "default";
        }
        {
          config = {
            "ipv4.address" = "10.10.21.1/24";
            "ipv4.dhcp.ranges" = "10.10.21.100-10.10.21.199";
            "ipv4.nat" = "true";
            "ipv6.address" = "auto";
          };
          description = "";
          name = "iabirdbr0";
          type = "bridge";
          project = "default";
        }
        {
          config = {
            "ipv4.address" = "10.10.22.1/24";
            "ipv4.dhcp.ranges" = "10.10.22.100-10.10.22.199";
            "ipv4.nat" = "true";
            "ipv6.address" = "auto";
          };
          description = "";
          name = "iabirddevbr0";
          type = "bridge";
          project = "default";
        }
      ];

      storage_pools = [
        {
          config = {
            source = "/var/lib/incus/storage-pools/default";
          };
          description = "";
          name = "default";
          driver = "btrfs";
        }
      ];

      storage_volumes = [];

      profiles = [
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
        {
          config = {};
          description = "";
          devices = {
            eth0 = {
              name = "eth0";
              network = "ipvlbr0";
              type = "nic";
            };
            root = {
              path = "/";
              pool = "default";
              type = "disk";
            };
          };
          name = "default";
          project = "pvl";
        }
        {
          config = {};
          description = "";
          devices = {
            eth0 = {
              name = "eth0";
              network = "iabirdbr0";
              type = "nic";
            };
            root = {
              path = "/";
              pool = "default";
              type = "disk";
            };
          };
          name = "default";
          project = "abird";
        }
        {
          config = {};
          description = "";
          devices = {
            eth0 = {
              name = "eth0";
              network = "iabirddevbr0";
              type = "nic";
            };
            root = {
              path = "/";
              pool = "default";
              type = "disk";
            };
          };
          name = "default";
          project = "abird-dev";
        }
      ];

      projects = [
        (mkRestrictedProject "pvl" "ipvlbr0")
        (mkRestrictedProject "abird" "iabirdbr0")
        (mkRestrictedProject "abird-dev" "iabirddevbr0")
      ];
      certificates = [
        {
          name = "pvl";
          type = "client";
          restricted = false;
          projects = [];
          certificate = builtins.readFile ../../data/secrets/incus/pvl.crt;
        }
        {
          name = "abird";
          type = "client";
          restricted = true;
          projects = [
            "abird"
            "abird-dev"
          ];
          certificate = builtins.readFile ../../data/secrets/incus/abird.crt;
        }
        {
          name = "abird-dev";
          type = "client";
          restricted = true;
          projects = ["abird-dev"];
          certificate = builtins.readFile ../../data/secrets/incus/abird-dev.crt;
        }
      ];
      cluster = null;
    };
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
  };
  networking.firewall.trustedInterfaces = ["incusbr0" "ipvlbr0" "iabirdbr0" "iabirddevbr0"];
}
