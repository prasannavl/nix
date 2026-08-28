{pkgs}: let
  document = {
    schema_version = 1;
    controller_reconcile_exclusions = ["move-local"];
    closeouts.move-app = {
      affected_hosts = ["source" "target" "proxy"];
      decision = "complete";
      projection_sha256 = builtins.hashString "sha256" "projection";
    };
    placements.demo.app = {
      host = "target";
      host_resource = "host:demo-target";
      transaction_id = "move-app";
      projection_sha256 = builtins.hashString "sha256" "projection";
    };
  };
  servicePlacements = import ../service-placements.nix {
    inherit (pkgs) lib;
    inherit document;
  };
  placement = {
    withServiceRoles = overrides: placement // {appliedOverrides = overrides;};
  };
  stack = {
    serviceRegistry.roles = {
      source.host = "demo-source";
      target.host = "demo-target";
    };
    withServiceRoles = overrides: stack // {appliedOverrides = overrides;};
    placements.primary = placement;
  };
  placed = servicePlacements.applyToStacks {demo = stack;};
  invalid = import ../service-placements.nix {
    inherit (pkgs) lib;
    document =
      document
      // {
        closeouts =
          document.closeouts
          // {
            move-app = document.closeouts.move-app // {decision = "guess";};
          };
      };
  };
in
  assert servicePlacements.document.closeouts.move-app.decision == "complete";
  assert servicePlacements.document.closeouts.move-app.controller_reconcile;
  assert servicePlacements.document.controller_reconcile_exclusions == ["move-local"];
  assert placed.demo.appliedOverrides == {app = "target";};
  assert placed.demo.placements.primary.appliedOverrides == {app = "target";};
  assert !(builtins.tryEval (builtins.deepSeq invalid.document true)).success;
    pkgs.runCommand "service-placements-flake-test" {} ''
      touch "$out"
    ''
