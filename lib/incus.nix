{...}: {
  virtualisation.incus = {
    enable = true;
    ui.enable = true;
    preseed = {
      config = {
        "core.https_address" = "[::]:8443";
      };

      networks = [
        {
          config = {
            "ipv4.address" = "auto";
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
  };
}
