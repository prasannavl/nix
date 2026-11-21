{
  mkBase = {
    mkNixosSystem,
    machineProfile,
    modules ? [],
    hostName ? "nixos",
    system ? "x86_64-linux",
  }:
    mkNixosSystem {
      inherit hostName machineProfile modules system;
    };
}
