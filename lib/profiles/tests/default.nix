{
  pkgs ?
    import <nixpkgs> {
      config.allowUnfree = true;
    },
}: {
  incusLxc = import ./incus-lxc.nix {inherit pkgs;};
}
