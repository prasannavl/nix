{hostName, ...}: {
  imports = [
    ../../lib/profiles/systemd-container.nix
    (import ../../lib/incus-vm.nix {inherit hostName;})
    ../../lib/podman.nix
    ../../lib/podman-compose
    ./packages.nix
    ./services.nix
    ./users.nix
  ];
}
