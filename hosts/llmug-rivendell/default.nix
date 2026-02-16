{...}: {
  imports = [
    ../../lib/nix.nix
    ../../lib/locale.nix
    ../../lib/sudo.nix
    ./sys.nix
    ./packages.nix
    ./firewall.nix
    ./image.nix
  ];

  networking.hostName = "llmug-rivendell";

  system.stateVersion = "25.11";
}
