_: {
  services.incusMachines.machines = {
    gap3-rivendell = {
      recreateTag = "2";
      ipv4Address = "10.10.30.10";
      config = {
        "security.privileged" = "false";
        "security.nesting" = "true";
        "security.syscalls.intercept.mount" = "true";
        "security.syscalls.intercept.mount.shift" = "true";
      };
      devices = {
        state = {
          source = "gap3-rivendell";
          path = "/var/lib";
          removalPolicy = "delete";
        };
        dev-dri = {
          source = "/dev/dri";
          path = "/dev/dri";
        };
        kfd = {
          type = "unix-char";
          source = "/dev/kfd";
          path = "/dev/kfd";
        };
      };
    };
  };

  virtualisation.incus = {
    enable = true;
    preseed = {
      config = {
        "core.https_address" = "[::]:8443";
      };

      networks = [
        {
          config = {
            "ipv4.address" = "10.10.30.1/24";
            "ipv4.dhcp.ranges" = "10.10.30.100-10.10.30.199";
            "ipv4.nat" = "true";
            "ipv6.address" = "auto";
          };
          description = "";
          name = "incusbr0";
          type = "";
          project = "default";
        }
      ];

      # dir driver avoids btrfs-on-btrfs (outer pvl-x2 pool is btrfs).
      storage_pools = [
        {
          config = {
            source = "/var/lib/incus/storage-pools/default";
          };
          description = "";
          name = "default";
          driver = "dir";
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
      ];

      projects = [];
      certificates = [];
      cluster = null;
    };
  };

  networking.firewall.trustedInterfaces = ["incusbr0"];
}
