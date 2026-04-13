{mkNixosSystem, ...}: {
  incus-base = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "nixos";
    modules = [./incus-base.nix];
  };
  gap3-base = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "nixos";
    modules = [./gap3-base.nix];
  };
}
