{
  inputs,
  config,
  lib,
  pkgs,
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
  mkRestrictedProject = name: network: extraConfig: {
    inherit name;
    description = "";
    config =
      isolatedProjectConfig
      // {
        restricted = "true";
        "restricted.containers.interception" = "block";
        "restricted.containers.lowlevel" = "block";
        "restricted.containers.privilege" = "unprivileged";
        "restricted.devices.disk" = "managed";
        "restricted.devices.nic" = "managed";
        "restricted.networks.access" = network;
        "restricted.storage-pools.access" = "default";
      }
      // extraConfig;
  };
in {
  services.incusMachines = {
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
      abird-dev = {
        project = "abird-dev";
      };
    };

    instances = {
      pvl-vlab = {
        ipv4Address = "10.10.20.10";
        removalPolicy = "delete-all";

        config = {
          "security.privileged" = "true";
          "security.nesting" = "true";
        };
        devices =
          {
            state = {
              source = "pvl-vlab";
              path = "/var/lib";
              removalPolicy = "keep";
            };
            # We use our lib belows, so we can control the "video" group
            # better. gpu applies render group to all incorrectly.
            # gpu = {type = "gpu";};
          }
          // incusLib.mkGpuDevices {
            card = 1;
            render = 128;
            kfd = true;
          };
      };

      pvl-vlab-1 = {
        ipv4Address = "10.10.20.30";
        removalPolicy = "delete-all";

        config = {
          "security.privileged" = "true";
          "security.nesting" = "true";
        };
        devices =
          {
            state = {
              source = "pvl-vlab-1";
              path = "/var/lib";
              removalPolicy = "keep";
            };
            incus-api = incusLib.mkIncusProxy {
              connectHost = "10.10.20.1";
            };
            delegated-certs = incusLib.mkCertDelegation "pvl";
          }
          // incusLib.mkGpuDevices {
            card = 1;
            render = 128;
            kfd = true;
          };
      };

      gap3-gondor = {
        image = inputs.self.nixosImages.gap3-base;
        ipv4Address = "10.10.20.20";
        removalPolicy = "delete-all";
        recreateTag = "3";

        config = {
          "security.nesting" = "true";
          "security.privileged" = "true";
        };
        devices =
          {
            state = {
              source = "gap3-gondor";
              path = "/var/lib";
              removalPolicy = "keep";
            };
            # We use our lib belows, so we can control the "video" group
            # better. gpu applies render group to all incorrectly.
            # gpu = {type = "gpu";};
          }
          // incusLib.mkGpuDevices {
            card = 1;
            render = 128;
            kfd = true;
          };
      };

      abird-nest = {
        project = "abird";
        ipv4Address = "10.10.100.31";
        removalPolicy = "delete-all";
        recreateTag = "1";

        config = {
          "security.nesting" = "true";
          "security.privileged" = "false";
        };
        devices = {
          state = {
            source = "abird-nest";
            path = "/var/lib";
            removalPolicy = "keep";
          };
          incus-api = incusLib.mkIncusProxy {
            connectHost = "10.10.20.1";
          };
          delegated-certs = incusLib.mkCertDelegation "abird";
          delegated-dev-certs = incusLib.mkCertDelegation "abird-dev";
        };
      };
    };
  };

  virtualisation.incus.preseed = {
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
          "ipv4.address" = "10.10.50.1/24";
          "ipv4.dhcp.ranges" = "10.10.50.100-10.10.50.199";
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
          "ipv4.address" = "10.10.100.1/24";
          "ipv4.dhcp.ranges" = "10.10.100.100-10.10.100.199";
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
          "ipv4.address" = "10.10.200.1/24";
          "ipv4.dhcp.ranges" = "10.10.200.100-10.10.200.199";
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
      (mkRestrictedProject "pvl" "ipvlbr0" {
        "restricted.containers.nesting" = "allow";
      })
      (mkRestrictedProject "abird" "iabirdbr0" {
        "restricted.containers.nesting" = "allow";
        "restricted.devices.disk" = "allow";
        "restricted.devices.disk.paths" = "/var/lib/incus-delegations/abird,/var/lib/incus-delegations/abird-dev";
        "restricted.devices.proxy" = "allow";
      })
      (mkRestrictedProject "abird-dev" "iabirddevbr0" {})
    ];
    certificates = [];
    cluster = null;
  };

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
  };
  networking.firewall.trustedInterfaces = ["incusbr0" "ipvlbr0" "iabirdbr0" "iabirddevbr0"];

  systemd.services.incus-preseed.preStart = let
    incus = "${config.virtualisation.incus.package}/bin/incus";
    jq = "${pkgs.jq}/bin/jq";
  in ''
    set -euo pipefail

    # Tightening project restrictions fails if an existing instance still
    # carries now-forbidden keys from an older generation. Remove only the
    # stale syscall-interception settings before applying the declarative
    # preseed.
    for project in pvl abird abird-dev; do
      if ! ${incus} project show "$project" >/dev/null 2>&1; then
        continue
      fi

      ${incus} list --project "$project" --format=json |
        ${jq} -r '.[].name' |
        while IFS= read -r instance; do
          [ -n "$instance" ] || continue

          ${incus} query "/1.0/instances/$instance?project=$project" |
            ${jq} -r '.config // {} | keys[] | select(startswith("security.syscalls.intercept."))' |
            while IFS= read -r key; do
              [ -n "$key" ] || continue
              ${incus} config unset --project "$project" "$instance" "$key" || true
            done
        done
    done
  '';
}
