import ../../lib/flake/prebuilt-configuration-family.nix {
  stacks = {
    pvl = import ./stacks/pvl.nix;
    "pvl-dev" = import ./stacks/pvl-dev.nix;
  };
}
