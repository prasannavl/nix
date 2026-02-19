{
  config,
  pkgs,
  ...
}: {
  imports = [
    ../../lib/profiles/systemd-container-minimal.nix
    ../../lib/hardware/nvidia.nix
    ../../lib/virtualization.nix
    ./sys.nix
    ./packages.nix
    ./firewall.nix
    ./podman.nix
    ./users.nix
  ];

  hardware.nvidia = {
    prime = {
      amdgpuBusId = "PCI:102:0:0";
      nvidiaBusId = "PCI:100:0:0";
    };
  };
  # The host kernel is used, we only choose this so
  # drivers like nvidia can compile for the right modules.
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
}
