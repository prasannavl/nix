{hostName, ...}: {
  imports = [
    ../../lib/profiles/systemd-container.nix
    (import ../../lib/incus-vm.nix {inherit hostName;})
    ../../lib/incus
    ../../lib/podman.nix
    ./cloudflare.nix
    ./incus.nix
    ./packages.nix
    ./firewall.nix
    ./services.nix
    ./users.nix
  ];
}
