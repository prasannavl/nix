{
  config,
  pkgs,
  ...
}: {
  imports = [
    ../../lib/profiles/systemd-container.nix
    ../../lib/podman.nix
    ../../lib/virtualization.nix
    ./packages.nix
    ./firewall.nix
    ./podman.nix
    ./services.nix
    ./users.nix
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/llmug 0755 llmug llmug -"
    "d /var/lib/llmug/machine 0700 root root -"
  ];

  services.openssh.hostKeys = [
    {
      path = "/var/lib/llmug/machine/ssh_host_ed25519_key";
      type = "ed25519";
    }
    {
      path = "/var/lib/llmug/machine/ssh_host_rsa_key";
      type = "rsa";
      bits = 4096;
    }
  ];
}
