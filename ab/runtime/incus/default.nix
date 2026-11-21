{pkgs}: {
  certs = import ./certs.nix;
  helpers = import ./lib.nix {lib = pkgs.lib;};
  helpersFor = {config}:
    import ./lib.nix {
      inherit config;
      lib = pkgs.lib;
    };
  images = import ./images.nix;
  nixos = import ./nixos.nix;
  profiles = {
    lxc = ./profiles/lxc.nix;
    vm = ./profiles/vm.nix;
  };
  scripts = {
    certs = ./helper-certs.py;
    manager = ./helper.sh;
  };
}
