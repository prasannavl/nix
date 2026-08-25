{pkgs}: let
  canonicalize = value: let
    unsigned = builtins.removeAttrs value ["projection_sha256"];
  in
    unsigned
    // {projection_sha256 = builtins.hashString "sha256" (builtins.toJSON unsigned);};
  unsignedProjection = {
    schema_version = 1;
    projection_id = "test-placement";
    intent_kind = "test";
    phase = "selected";
    generation = 1;
    intent = ["opaque" 1];
    intent_sha256 = builtins.hashString "sha256" (builtins.toJSON ["opaque" 1]);
    resources = [
      {
        id = "app:source";
        role = "source";
        kind = "service";
        name = "app";
        endpoint = {
          host = "source";
          host_resource = "host:demo-source";
          resource = "service:app";
          hold_epoch = "app:source-held";
          transaction_id = "test-placement--app";
          activation_job_id = null;
          desired_state = "held";
        };
      }
      {
        id = "app:target";
        role = "target";
        kind = "service";
        name = "app";
        endpoint = {
          host = "target";
          host_resource = "host:demo-target";
          resource = "service:app";
          hold_epoch = null;
          transaction_id = null;
          activation_job_id = null;
          desired_state = "active";
        };
      }
    ];
    effects = [
      {
        kind = "service_placement";
        scope = "demo";
        service = "app";
        host = "target";
        host_resource = "host:demo-target";
      }
      {
        kind = "route_profile";
        scope = "demo";
        service = "app";
        profile = "app@host:demo-target";
        baseline_profile = "app@host:demo-source";
        executor_host = "proxy";
        executor_host_resource = "host:demo-proxy";
        executor_resource = "service:proxy";
        profiles = [
          {
            profile = "app@host:demo-source";
            endpoint_host = "source";
            endpoint_host_resource = "host:demo-source";
            resource = "service:app";
          }
          {
            profile = "app@host:demo-target";
            endpoint_host = "target";
            endpoint_host_resource = "host:demo-target";
            resource = "service:app";
          }
        ];
      }
    ];
    activation_requirement = null;
    previous_projection_sha256 = null;
    previous_repository_revision = null;
  };
  projection = canonicalize unsignedProjection;
  unheldIntent = {
    projection_id = "hold-demo";
    host = "source";
    host_resource = "host:demo-source";
    resource = "service:demo";
  };
  unheldProjection = canonicalize {
    schema_version = 1;
    projection_id = "hold-demo";
    intent_kind = "resource_hold";
    phase = "unheld";
    generation = 2;
    intent = unheldIntent;
    intent_sha256 = builtins.hashString "sha256" (builtins.toJSON unheldIntent);
    resources = [
      {
        id = "resource";
        role = "subject";
        kind = "service";
        name = "demo";
        endpoint = {
          host = "source";
          host_resource = "host:demo-source";
          resource = "service:demo";
          hold_epoch = "hold-v1";
          transaction_id = "hold-demo";
          activation_job_id = null;
          desired_state = "unheld";
        };
      }
    ];
    effects = [];
    activation_requirement = null;
    previous_projection_sha256 = builtins.concatStringsSep "" (pkgs.lib.replicate 64 "a");
    previous_repository_revision = "rev-1";
  };
  unheldPhaseProjection = import ../phase-projection.nix {
    inherit (pkgs) lib;
    documents = [unheldProjection];
  };
  phaseProjection = import ../phase-projection.nix {
    inherit (pkgs) lib;
    documents = [projection];
  };
  unknownFieldProjection = projection // {unexpected = true;};
  invalidPhaseProjection = import ../phase-projection.nix {
    inherit (pkgs) lib;
    documents = [unknownFieldProjection];
  };
  invalidDocuments = map (document:
    import ../phase-projection.nix {
      inherit (pkgs) lib;
      documents = [document];
    }) [
    (canonicalize (unsignedProjection
      // {
        intent = ["opaque" 1.5];
        intent_sha256 = builtins.hashString "sha256" (builtins.toJSON ["opaque" 1.5]);
      }))
    (canonicalize (unsignedProjection
      // {
        resources =
          unsignedProjection.resources
          ++ [
            (builtins.head unsignedProjection.resources
              // {
                id = "other:target";
                name = "other";
              })
          ];
      }))
    (canonicalize (unsignedProjection
      // {
        resources = map (resource: resource // {endpoint = resource.endpoint // {hold_epoch = "held-before-active";};}) unsignedProjection.resources;
      }))
    (canonicalize (unsignedProjection // {projection_id = "contains spaces";}))
  ];
  reversedProjection = canonicalize (unsignedProjection // {effects = pkgs.lib.reverseList unsignedProjection.effects;});
  reversedPhaseProjection = import ../phase-projection.nix {
    inherit (pkgs) lib;
    documents = [reversedProjection];
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
    placements = {
      primary = placement;
      secondary = placement;
    };
  };
  projected = phaseProjection.applyToStacks {demo = stack;};
in
  assert builtins.length phaseProjection.documents == 1;
  assert (builtins.head unheldPhaseProjection.documents).phase == "unheld";
  assert !(builtins.tryEval (builtins.deepSeq invalidPhaseProjection.documents true)).success;
  assert pkgs.lib.all (invalid: !(builtins.tryEval (builtins.deepSeq invalid.documents true)).success) invalidDocuments;
  assert builtins.length reversedPhaseProjection.documents == 1;
  assert projected.demo.appliedOverrides == {app = "target";};
  assert projected.demo.placements.primary.appliedOverrides == {app = "target";};
  assert projected.demo.placements.secondary.appliedOverrides == {app = "target";};
    pkgs.runCommand "phase-projection-flake-test" {} ''
      touch "$out"
    ''
