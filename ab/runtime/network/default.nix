{pkgs}: {
  tunnels = import ./tunnels {lib = pkgs.lib;};
  wireguard = import ./wireguard.nix {
    inherit pkgs;
    lib = pkgs.lib;
  };
}
