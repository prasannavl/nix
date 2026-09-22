{pkgs}: {
  lib = import ./lib.nix {inherit pkgs;};
  module = import ./module.nix {inherit pkgs;};
  projection = import ./projection.nix {inherit pkgs;};
}
