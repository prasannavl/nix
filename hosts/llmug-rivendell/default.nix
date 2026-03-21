{hostName, ...}: {
  imports = [
    ../../lib/profiles/systemd-container.nix
    (import ../../lib/incus-vm.nix {inherit hostName;})
    ../../lib/flake/podman.nix
    ../../lib/virtualization.nix
    ./cloudflare.nix
    ./packages.nix
    ./firewall.nix
    ./podman.nix
    ./services.nix
    ./users.nix
  ];
}
