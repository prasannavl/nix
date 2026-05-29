{
  mkNixosSystem,
  stacks,
  ...
}: {
  incus-base = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "nixos";
    stack = stacks.all;
    modules = [./incus-base.nix];
  };
  gap3-base = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "nixos";
    stack = stacks.pvl;
    modules = [./gap3-base.nix];
  };
}
