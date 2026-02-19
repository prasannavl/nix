{pkgs, ...}: {
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
            "ipv4.address" = "10.42.0.1/24";
            "ipv4.dhcp.ranges" = "10.42.0.100-10.42.0.199";
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
  };
}
