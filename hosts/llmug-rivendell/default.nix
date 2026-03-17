{hostName, ...}: {
  imports = [
    ../../lib/profiles/systemd-container.nix
    (import ../../lib/incus-machine.nix {inherit hostName;})
    ../../lib/podman.nix
    ../../lib/virtualization.nix
    ./cloudflare.nix
    ./packages.nix
    ./firewall.nix
    ./podman.nix
    ./services.nix
    ./users.nix
  ];
}
