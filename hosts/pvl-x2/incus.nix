{...}: {
  services.incusMachines = {
    imageTag = "1";

    machines = {
      llmug-rivendell = {
        ipv4Address = "10.10.20.10";
        removalPolicy = "delete-all";
        recreateTag = "2";
        bootTag = "1";

        config = {
          "security.privileged" = "true";
          "security.nesting" = "true";
        };
        devices = {
          state = {
            source = "llmug-rivendell";
            path = "/var/lib";
            removalPolicy = "delete";
          };
          gpu = {type = "gpu";};
          kfd = {
            type = "unix-char";
            source = "/dev/kfd";
            path = "/dev/kfd";
          };
        };
      };
      gap3-gondor = {
        ipv4Address = "10.10.20.11";
        removalPolicy = "delete-all";
        recreateTag = "3";
        bootTag = "1";

        config = {
          "security.nesting" = "true";
          "security.privileged" = "true";
        };
        devices = {
          state = {
            source = "gap3-gondor";
            path = "/var/lib";
            removalPolicy = "delete";
          };
          gpu = {type = "gpu";};
          kfd = {
            type = "unix-char";
            source = "/dev/kfd";
            path = "/dev/kfd";
          };
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
        type = "";
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
    ];

    projects = [];
    certificates = [];
    cluster = null;
  };
}
