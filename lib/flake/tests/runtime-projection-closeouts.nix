{pkgs}: let
  digest = builtins.hashString "sha256" "projection";
  document = {
    schema_version = 1;
    closeouts.move-host = {
      affected_hosts = ["source" "target"];
      decision = "complete";
      projection_sha256 = digest;
    };
    controller_reconcile_exclusions = ["local-resource-hold"];
  };
  evaluate = candidate:
    import ../runtime-projection-closeouts.nix {
      inherit (pkgs) lib;
      document = candidate;
    };
  valid = evaluate document;
  duplicateHost = evaluate (
    document
    // {
      closeouts.move-host = document.closeouts.move-host // {affected_hosts = ["source" "source"];};
    }
  );
  retiredPlacementField = evaluate (document // {placements = {};});
in
  assert valid.closeouts.move-host.controller_reconcile;
  assert valid.closeouts.move-host.projection_sha256 == digest;
  assert valid.controller_reconcile_exclusions == ["local-resource-hold"];
  assert !(builtins.tryEval (builtins.deepSeq duplicateHost true)).success;
  assert !(builtins.tryEval (builtins.deepSeq retiredPlacementField true)).success;
    pkgs.runCommand "runtime-projection-closeouts-flake-test" {} ''
      touch "$out"
    ''
