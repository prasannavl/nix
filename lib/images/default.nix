{
  mkNixosSystem,
  stacks,
  ...
}: let
  incusLxcBase = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "nixos";
    stack = stacks.all;
    modules = [./incus-lxc-base.nix];
  };
in {
  incus-lxc-base = incusLxcBase;
  incus-vm-base = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "nixos";
    stack = stacks.all;
    modules = [./incus-vm-base.nix];
  };

  # Compatibility aliases for local host definitions that still reference the
  # pre-VM split names directly.
  incus-base = incusLxcBase;
  gap3-base = mkNixosSystem {
    system = "x86_64-linux";
    hostName = "nixos";
    stack = stacks.pvl;
    modules = [./gap3-base.nix];
  };
}
