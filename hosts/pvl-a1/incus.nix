{pkgs, ...}: {
  services.incusMachines.global.hostSuspend = {
    enable = true;
    defaultPolicy = "stop";
    includeVirtualMachines = false;
  };
  services.incusMachines.global.certificates = [
    {
      name = "pvl";
      type = "client";
      restricted = false;
      projects = [];
      certificate = builtins.readFile ../../data/secrets/incus/pvl.crt;
    }
  ];

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

  boot.kernel.sysctl = {
    "net.ipv4.ip_forward" = 1;
  };
  networking.firewall.trustedInterfaces = ["incusbr0"];
}
