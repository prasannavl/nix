{
  pkgs ?
    import <nixpkgs> {
      config.allowUnfree = true;
    },
}: {
  lib-profiles-incus-lxc = import ./profiles-incus-lxc.nix {inherit pkgs;};
}
