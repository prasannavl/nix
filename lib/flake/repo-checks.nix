# Repository-owned composition; shared assembly receives this function by injection.
# Identity checks live under tests/<repository>/ and register exactly once.
{
  pkgs,
  crane ? null,
  ...
}: let
  topologyChecks = import ./tests/pvl {inherit pkgs crane;};
  policyChecks = {
    pvl-nix-builder-gc-defaults = import ../tests/pvl/nix-builder-gc-coordination.nix {pkgs = pkgs;};
  };
in
  assert builtins.intersectAttrs topologyChecks policyChecks == {};
    topologyChecks // policyChecks
