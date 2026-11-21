# Repository-owned composition; shared assembly receives this function by injection.
# Identity checks live under tests/<repository>/ and register exactly once.
{
  pkgs,
  crane ? null,
  ...
}: let
  topologyChecks = import ./tests/repository/pvl {inherit pkgs crane;};
  policyChecks = {
    # Preserve the published destination check name at the repository boundary.
    lib-flake-configuration-family = import ./tests/repository/config-family.nix {inherit pkgs;};
    pvl-nix-builder-gc-defaults = import ./tests/pvl/nix-builder-gc-coordination.nix {pkgs = pkgs;};
  };
in
  assert builtins.intersectAttrs topologyChecks policyChecks == {};
    topologyChecks // policyChecks
