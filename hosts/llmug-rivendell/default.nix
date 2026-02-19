{...}: {
  imports = [
    ../../lib/profiles/systemd-container-minimal.nix
    ./sys.nix
    ./packages.nix
    ./firewall.nix
    ../../users/pvl
  ];

  networking.hostName = "llmug-rivendell";
  system.stateVersion = "25.11";
}
