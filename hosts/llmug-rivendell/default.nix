{pkgs, ...}: {
  imports = [
    ../../lib/profiles/systemd-container-minimal.nix
    ../../lib/hardware/nvidia.nix
    ../../lib/virtualization.nix
    ./sys.nix
    ./packages.nix
    ./firewall.nix
    ./podman.nix
    ../../users/pvl
  ];

  hardware.nvidia = {
    nvidiaPersistenced = false;
    dynamicBoost.enable = false;
    prime = {
      offload.enable = true;
      reverseSync.enable = true;
      amdgpuBusId = "PCI:102:0:0";
      nvidiaBusId = "PCI:100:0:0";
    };
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;

  systemd.tmpfiles.rules = [
    "d /var/lib/llmug 0755 root root -"
    "d /var/lib/llmug/ssh 0700 root root -"
  ];

  services.openssh.hostKeys = [
    {
      path = "/var/lib/llmug/ssh/ssh_host_ed25519_key";
      type = "ed25519";
    }
    {
      path = "/var/lib/llmug/ssh/ssh_host_rsa_key";
      type = "rsa";
      bits = 4096;
    }
  ];
  services.openssh.settings.PermitRootLogin = "no";

  networking.hostName = "llmug-rivendell";
  system.stateVersion = "25.11";
}
