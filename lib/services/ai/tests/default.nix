{pkgs}: {
  lib = import ./lib.nix {inherit pkgs;};
  module = import ./module.nix {inherit pkgs;};
}
