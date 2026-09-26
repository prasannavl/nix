/*
The Pvl repository identity area file for the shared flake-isolated
check (../default.nix): product wiring assertions for Pvl-only
applications. See the directory's default.nix header and
.agents/docs/design-patterns/shared-test-areas.md. Asserts may force only
products, promotions, and non-identity checks of the injected instance:
forcing this instance's identity check values would recurse infinitely
(the repo-checks -> identity -> repo-checks cycle terminates only by
laziness).
*/
{pkgs}: let
  fakeFlakeUtils = {
    lib = {
      defaultSystems = [pkgs.stdenv.hostPlatform.system];
      eachSystem = systems: f: let
        outputsBySystem = builtins.listToAttrs (
          map (name: {
            inherit name;
            value = f name;
          })
          systems
        );
        outputNames = pkgs.lib.unique (
          builtins.concatMap (name: builtins.attrNames outputsBySystem.${name}) systems
        );
      in
        builtins.listToAttrs (
          map (outputName: {
            name = outputName;
            value = builtins.listToAttrs (
              map (name: {
                inherit name;
                value = outputsBySystem.${name}.${outputName};
              })
              systems
            );
          })
          outputNames
        );
    };
  };
  flakeLib = import ../../default.nix {
    inputs = {};
    nixpkgs = {lib = pkgs.lib;};
    flake-utils = fakeFlakeUtils;
    overlays = [];
    stacks = {};
    repoChecksFn = import ../../repo-checks.nix;
  };
  outputs = flakeLib.withPkgs pkgs;
in {
  # The codex-wrapper `cr` app is Pvl-only product wiring; the shared
  # lib/flake/tests/default.nix asserts only the products both repositories
  # carry.
  pvl-flake-isolated = assert outputs.apps.cr.program == "${outputs.packages.codex-wrapper}/bin/cr";
  assert outputs.packages.nats-streams.meta.mainProgram == "nats-streams";
  assert builtins.isFunction outputs.packages.nats-streams.passthru.mkStreamSet;
  assert toString outputs.packages.nats-streams.passthru.nixosModule.__moduleSourcePath == toString ../../../../pkgs/support/nats-streams/default.nix;
    pkgs.runCommand "pvl-flake-isolated-test" {} ''
      touch "$out"
    '';
}
