{...}: {
  imports = [
    ../common/all.nix
    ../../nix/incus.nix
    ../../ab/runtime/podman/host.nix
    ./cloudflare.nix
    ./incus.nix
    ./packages.nix
    ./firewall.nix
    ./services.nix
    ./users.nix
  ];
}
