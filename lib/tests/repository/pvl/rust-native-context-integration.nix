# Cached real nixpkgs/Crane constructor + consumer integration only.
# Synthetic manager/agent/bridge shapes, never full-root package evaluation.
{
  pkgs,
  snapshot ? null,
}: let
  tested = import ../../../../ab/core/packaging/rust/tests/native-context.nix {inherit pkgs snapshot;};
  shellRegression = import ../../../../ab/core/packaging/rust/tests/native-shell.nix {inherit pkgs;};
in
  assert (pkgs.craneLib or null) != null;
    pkgs.runCommand "pvl-rust-native-context-integration-test" {
      passthru = {inherit (tested) assertions assertionCount passed;};
    } ''
      ${shellRegression.script}
      touch "$out"
    ''
