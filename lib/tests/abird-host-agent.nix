{pkgs}: let
  lib = pkgs.lib;
  fakeAgent = pkgs.writeShellScriptBin "abird-host-agent" ''
    manifest=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --manifest)
          shift
          manifest="$1"
          ;;
      esac
      shift
    done
    [ -n "$manifest" ] || exit 0
    if [ "''${ABIRD_TEST_BAD_DEFERRED_COUNT-}" = 1 ]; then
      ${lib.getExe pkgs.jq} -c '{ok: true, operation: "desired_resource_states_preflight", result: {count: (.resources | length), deferred_held: 0, resources: [.resources[] | if .id == "service:move-source" then {resource: .id, outcome: "deferred_held", reason: "activation_job_specification_conflict", detail: "terminal failed activation job differs"} else {resource: .id, outcome: "converge"} end]}}' "$manifest"
    elif [ "''${ABIRD_TEST_DEFERRED-}" = 1 ]; then
      ${lib.getExe pkgs.jq} -c '{ok: true, operation: "desired_resource_states_preflight", result: {count: (.resources | length), deferred_held: 1, resources: [.resources[] | if .id == "service:move-source" then {resource: .id, outcome: "deferred_held", reason: "activation_job_specification_conflict", detail: "terminal failed activation job differs"} else {resource: .id, outcome: "converge"} end]}}' "$manifest"
    else
      ${lib.getExe pkgs.jq} -c '{ok: true, operation: "desired_resource_states_preflight", result: {count: (.resources | length), deferred_held: 0, resources: [.resources[] | {resource: .id, outcome: "converge"}]}}' "$manifest"
    fi
  '';
  minimalSystemModule = {
    boot.loader.grub.devices = ["nodev"];
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
    };
  };
  resource = "service:demo";
  instanceResource = "instance:demo-instance";
  extraResource = "group:demo";
  transaction = "migration-test";
  receiptRequirement = builtins.concatStringsSep "" (lib.replicate 64 "c");
  previousRouteDigest = builtins.concatStringsSep "" (lib.replicate 64 "d");
  moveTargetResource = "service:move-target";
  moveSourceResource = "service:move-source";
  moveTargetHoldFileName = "${builtins.hashString "sha256" moveTargetResource}.json";
  moveSourceHoldFileName = "${builtins.hashString "sha256" moveSourceResource}.json";
  phaseProjection = import ../services/abird-host-agent/phase-projection.nix {lib = lib;};
  canonicalProjection = value: let
    withIntentDigest = value // {intent_sha256 = builtins.hashString "sha256" (builtins.toJSON value.intent);};
    unsigned = builtins.removeAttrs withIntentDigest ["projection_sha256"];
  in
    unsigned
    // {projection_sha256 = builtins.hashString "sha256" (builtins.toJSON unsigned);};
  seededResource = "service:seeded-source";
  seededDesiredStates = phaseProjection.localDesiredResourceStates {
    hostResource = "host:nixos";
    projection = canonicalProjection {
      schema_version = 1;
      projection_id = transaction;
      intent_kind = "move";
      intent = ["service" "seeded"];
      phase = "seeded";
      generation = 1;
      resources = [
        {
          id = "seeded:source";
          role = "source";
          kind = "service";
          name = "seeded";
          endpoint = {
            host = "source";
            host_resource = "host:nixos";
            resource = seededResource;
            desired_state = "active";
            hold_epoch = null;
            transaction_id = null;
            activation_job_id = null;
          };
        }
        {
          id = "seeded:target";
          role = "target";
          kind = "service";
          name = "seeded";
          endpoint = {
            host = "target";
            host_resource = "host:target";
            resource = "service:seeded-target";
            desired_state = "held";
            hold_epoch = "seeded:target-pre-cutover";
            transaction_id = "move-seeded--item-001";
            activation_job_id = null;
          };
        }
      ];
      effects = [];
      activation_requirement = null;
      previous_projection_sha256 = null;
      previous_repository_revision = null;
    };
  };
  activePhaseProjection = canonicalProjection {
    schema_version = 1;
    projection_id = transaction;
    intent_kind = "move";
    intent = {service = "demo";};
    phase = "cutover";
    generation = 3;
    resources = [
      {
        id = "move:source";
        role = "source";
        kind = "service";
        name = "demo";
        endpoint = {
          host = "source";
          host_resource = "host:nixos";
          resource = moveTargetResource;
          desired_state = "held";
          hold_epoch = "move:source-prepared";
          transaction_id = "move-demo--item-001";
          activation_job_id = null;
        };
      }
      {
        id = "move:target";
        role = "target";
        kind = "service";
        name = "demo";
        endpoint = {
          host = "target";
          host_resource = "host:nixos";
          resource = moveSourceResource;
          desired_state = "active";
          hold_epoch = "move:target-pre-cutover";
          transaction_id = "move-demo--item-001";
          activation_job_id = "move-demo--item-001-cutover-activate-target";
        };
      }
    ];
    effects = [];
    activation_requirement = {
      kind = "prepared_receipt";
      requirement_sha256 = receiptRequirement;
    };
    previous_projection_sha256 = null;
    previous_repository_revision = null;
  };
  projectionDigest = activePhaseProjection.projection_sha256;
  holdFileName = "${builtins.hashString "sha256" resource}.json";
  holdFile = "/var/lib/abird-host-agent/holds/${holdFileName}";
  activationAuthorization = projectedResource: "/var/lib/abird-host-agent/activation-authorizations/${builtins.hashString "sha256" projectedResource}.json";
  hostResource = "host:nixos";
  hostHoldFile = "/var/lib/abird-host-agent/holds/${builtins.hashString "sha256" hostResource}.json";
  evalConfig = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    specialArgs.phaseProjections = [activePhaseProjection];
    specialArgs.projectionAdmission.serviceMoves = {
      schema_version = 1;
      adapter = "stateful-service-placement";
      authority_paths = [
        "service-placement-contract.json"
        "desired-resource-states.json"
        "resources.json"
      ];
      document = {
        schema_version = 3;
        predecessors = {
          "1".scope_aliases = {};
          "2".scope_aliases = {};
        };
        placements.abird.zulip = {
          migration_kind = "stateful";
          role = "corp";
        };
        moves = {};
      };
    };
    modules = [
      ../services/abird-host-agent
      {
        services.abird-host-agent = {
          enable = true;
          package = fakeAgent;
          declaredHolds.${resource} = transaction;
          services = {
            demo = {
              units = [
                {
                  scope = "system";
                  unit = "demo.service";
                }
                {
                  scope = "user";
                  user = "operator";
                  unit = "demo-user.service";
                }
              ];
              dataPaths = ["/var/lib/demo"];
              operations.seed = ["${pkgs.coreutils}/bin/true" "--seed"];
              transfers.seed = {
                source = "/var/lib/demo-source";
                destination = "/var/lib/demo";
              };
              fileStates.route-target = {
                path = "/var/lib/abird-host-agent/routes/demo";
                content = "target\n";
                acceptedPreviousSha256 = [previousRouteDigest];
                validationArgv = ["${pkgs.coreutils}/bin/true" "--check-route"];
                reloadServices = [
                  {
                    scope = "system";
                    unit = "demo.service";
                  }
                ];
              };
            };
            move-target = {
              units = [{unit = "move-target.service";}];
              dataPaths = ["/var/lib/move-target"];
            };
            move-source = {
              units = [{unit = "move-source.service";}];
              dataPaths = ["/var/lib/move-source"];
            };
          };
          instances.demo-instance.dataPaths = ["/var/lib/demo-instance"];
          extraResources.${extraResource}.operations.inspect = [
            "${pkgs.coreutils}/bin/true"
            "--inspect"
          ];
        };
        systemd = {
          services = {
            demo.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/true";
            move-target.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/true";
            move-source.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/true";
          };
          targets.demo-ready = {};
          user = {
            services.demo-user.serviceConfig.ExecStart = "${pkgs.coreutils}/bin/true";
            targets.demo-user-ready = {};
          };
        };
        users.users.operator = {
          isNormalUser = true;
          uid = 2001;
        };
      }
      {
        services.abird-host-agent.services.demo = {
          readiness = [
            {
              type = "path";
              path = "/var/lib/demo";
              requirement = "directory";
            }
          ];
          gatedSystemUnits = ["demo-ready.target"];
          gatedUserUnits.operator = ["demo-user-ready.target"];
        };
      }
    ];
  };
  collisionEval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      minimalSystemModule
      ../services/abird-host-agent
      {
        services.abird-host-agent = {
          enable = true;
          package = fakeAgent;
          services.demo.dataPaths = ["/var/lib/demo"];
          extraResources."service:demo".dataPaths = ["/var/lib/shadow"];
        };
      }
    ];
  };
  collisionResult = builtins.tryEval collisionEval.config.system.build.toplevel;
  rootPathEval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      minimalSystemModule
      ../services/abird-host-agent
      {
        services.abird-host-agent = {
          enable = true;
          package = fakeAgent;
          services.demo.dataPaths = ["/"];
        };
      }
    ];
  };
  rootPathResult = builtins.tryEval rootPathEval.config.system.build.toplevel;
  unnamedUserEval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      minimalSystemModule
      ../services/abird-host-agent
      {
        services.abird-host-agent = {
          enable = true;
          package = fakeAgent;
          services.demo.units = [
            {
              scope = "user";
              unit = "demo.service";
            }
          ];
        };
      }
    ];
  };
  unnamedUserResult = builtins.tryEval unnamedUserEval.config.system.build.toplevel;
  missingUserUidEval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      minimalSystemModule
      ../services/abird-host-agent
      {
        services.abird-host-agent = {
          enable = true;
          package = fakeAgent;
          services.demo.units = [
            {
              scope = "user";
              user = "missing";
              unit = "demo.service";
            }
          ];
        };
      }
    ];
  };
  missingUserUidResult = builtins.tryEval missingUserUidEval.config.system.build.toplevel;
  invalidAdmissionEval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    specialArgs.projectionAdmission.serviceMoves = {
      schema_version = 1;
      adapter = "stateful-service-placement";
      authority_paths = ["../outside-authority.json"];
    };
    modules = [
      minimalSystemModule
      ../services/abird-host-agent
      {
        services.abird-host-agent = {
          enable = true;
          package = fakeAgent;
        };
      }
    ];
  };
  invalidAdmissionResult = builtins.tryEval invalidAdmissionEval.config.system.build.toplevel;
  emptyEvidenceHostEval = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      minimalSystemModule
      ../services/abird-host-agent
      {
        networking.hostName = "";
        services.abird-host-agent = {
          enable = true;
          package = fakeAgent;
        };
      }
    ];
  };
  emptyEvidenceHostResult = builtins.tryEval emptyEvidenceHostEval.config.system.build.toplevel;
  evaluateAdmission = projectionAdmission: let
    evaluation = import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      inherit pkgs;
      specialArgs.projectionAdmission = projectionAdmission;
      modules = [
        minimalSystemModule
        ../services/abird-host-agent
        {
          services.abird-host-agent = {
            enable = true;
            package = fakeAgent;
          };
        }
      ];
    };
  in
    builtins.tryEval evaluation.config.system.build.toplevel;
  malformedAdmissionResults = map (admission: evaluateAdmission {candidate = admission;}) [
    {
      enabled = true;
      schema_version = 1;
      authority_paths = [];
    }
    "malformed"
    {
      enabled = "true";
      schema_version = 1;
      adapter = "stateful-service-placement";
      authority_paths = [];
    }
    {
      enabled = true;
      schema_version = 1;
      adapter = "stateful-service-placement";
      authority_paths = [".git/authority.json"];
    }
    {
      enabled = true;
      schema_version = 1;
      adapter = "stateful-service-placement";
      authority_paths = ["unsafe\npath.json"];
    }
    {
      enabled = true;
      schema_version = 1;
      adapter = "stateful-service-placement";
      authority_paths = [];
    }
    {
      enabled = true;
      schema_version = 1;
      adapter = "stateful-service-placement";
      authority_paths = [];
      document = {
        schema_version = 2;
        placements = {};
        moves = {};
      };
    }
  ];
  missingAdmissionDocumentResult = evaluateAdmission {
    serviceMoves = {
      enabled = true;
      schema_version = 1;
      adapter = "stateful-service-placement";
      authority_paths = [];
    };
  };
  invalidAdmissionDocumentResult = evaluateAdmission {
    serviceMoves = {
      enabled = true;
      schema_version = 1;
      adapter = "stateful-service-placement";
      authority_paths = [];
      document = {
        schema_version = 2;
        placements = {};
        moves = {};
      };
    };
  };
  disabledMalformedAdmissionResult = evaluateAdmission {
    serviceMoves = {
      schema_version = 1;
      adapter = "stateful-service-placement";
      authority_paths = [
        "service-placement-contract.json"
        "desired-resource-states.json"
        "resources.json"
      ];
      document = {
        schema_version = 3;
        predecessors = {
          "1".scope_aliases = {};
          "2".scope_aliases = {};
        };
        placements = {};
        moves = {};
      };
    };
    disabled = {
      enabled = false;
      schema_version = "invalid";
      adapter = 42;
      authority_paths = "invalid";
      unexpected = true;
    };
  };
  config = evalConfig.config;
  conditions = [
    "|!${holdFile}"
    "|${activationAuthorization resource}"
    "!${hostHoldFile}"
  ];
  holdCommands = config.systemd.services.abird-host-agent-holds.serviceConfig.ExecStart;
  holdActivation = config.system.activationScripts.abird-host-agent-holds;
  generationPreSwitchCheck = config.system.preSwitchChecks.abird-host-agent-generation;
  generationPreflightPackage = builtins.head (lib.filter (package: lib.hasInfix "abird-host-agent-generation-preflight" package.name) config.environment.systemPackages);
  configuredAgent = builtins.head (lib.splitString " " config.systemd.services.abird-host-agent-jobs.serviceConfig.ExecStart);
  configuredRoot = builtins.dirOf (builtins.dirOf configuredAgent);
  resourceManifest = config.environment.etc."abird-host-agent/resources.json".source;
  desiredResourceStateManifest = config.environment.etc."abird-host-agent/desired-resource-states.json".source;
  servicePlacementAdmissionManifest = config.environment.etc."abird-host-agent/service-placement-contract.json".source;
  generationAdmissionRegistryManifest = config.environment.etc."abird-host-agent/generation-admission-registry.json".source;
  desiredTargetDeclaration = builtins.fromJSON config.environment.etc."abird-host-agent/desired-resource-states/${moveTargetHoldFileName}".text;
  runuserProgram = lib.getExe' pkgs.util-linux "runuser";
in
  assert !collisionResult.success;
  assert !rootPathResult.success;
  assert !unnamedUserResult.success;
  assert !missingUserUidResult.success;
  assert !invalidAdmissionResult.success;
  assert !emptyEvidenceHostResult.success;
  assert lib.all (result: !result.success) malformedAdmissionResults;
  assert !missingAdmissionDocumentResult.success;
  assert !invalidAdmissionDocumentResult.success;
  assert disabledMalformedAdmissionResult.success;
  assert seededDesiredStates.${seededResource}.state == "active";
  assert seededDesiredStates.${seededResource}.holdEpoch == null;
  assert seededDesiredStates.${seededResource}.activationRequirementDigest == null;
  assert config.systemd.services.demo.unitConfig.ConditionPathExists == conditions;
  assert config.systemd.targets.demo-ready.unitConfig.ConditionPathExists == conditions;
  assert config.systemd.user.services.demo-user.unitConfig.ConditionPathExists == conditions;
  assert config.systemd.user.targets.demo-user-ready.unitConfig.ConditionPathExists == conditions;
  assert builtins.elem "abird-host-agent-holds-ready.service" config.systemd.user.services.demo-user.requires;
  assert builtins.elem "abird-host-agent-holds-ready.service" config.systemd.user.services.demo-user.after;
  assert builtins.elem "abird-host-agent-holds-ready.service" config.systemd.user.targets.demo-user-ready.requires;
  assert config.systemd.user.services.abird-host-agent-holds-ready.serviceConfig.Type == "oneshot";
  assert !(config.systemd.user.services.abird-host-agent-holds-ready.serviceConfig ? TimeoutStartSec);
  assert config.systemd.user.services.abird-host-agent-holds-ready.restartIfChanged == true;
  assert config.systemd.user.services.abird-host-agent-holds-ready.restartTriggers == [resourceManifest desiredResourceStateManifest];
  assert builtins.elem "abird-host-agent-holds.service" config.systemd.services.demo.requires;
  assert builtins.elem "incus.service" config.systemd.services.abird-host-agent-holds.after;
  assert builtins.elem "user@2001.service" config.systemd.services.abird-host-agent-holds.wants;
  assert builtins.elem "user@2001.service" config.systemd.services.abird-host-agent-holds.after;
  assert lib.hasInfix "/run/abird-host-agent-holds-ready" config.systemd.services.abird-host-agent-holds.serviceConfig.ExecStopPost;
  assert config.systemd.services.abird-host-agent-holds.restartTriggers == [desiredResourceStateManifest];
  assert config.systemd.services.move-target.unitConfig.ConditionPathExists
  == [
    "|!/var/lib/abird-host-agent/holds/${moveTargetHoldFileName}"
    "|${activationAuthorization moveTargetResource}"
    "!${hostHoldFile}"
  ];
  assert config.systemd.services.move-source.unitConfig.ConditionPathExists
  == [
    "|!/var/lib/abird-host-agent/holds/${moveSourceHoldFileName}"
    "|${activationAuthorization moveSourceResource}"
    "!${hostHoldFile}"
  ];
  assert builtins.length holdCommands == 4;
  assert lib.hasInfix "_reconcile hold declare" (builtins.head holdCommands);
  assert lib.hasInfix "--defer-enforcement" (builtins.head holdCommands);
  assert lib.hasInfix "_reconcile desired-resource-holds" (builtins.elemAt holdCommands 1);
  assert lib.hasInfix "_reconcile hold apply" (builtins.elemAt holdCommands 2);
  assert lib.hasInfix "/run/abird-host-agent-holds-ready" (lib.last holdCommands);
  assert holdActivation.deps == ["etc" "users"];
  assert holdActivation.supportsDryActivation == false;
  assert lib.hasInfix "switch|test" holdActivation.text;
  assert lib.hasInfix "systemd-tmpfiles --create" holdActivation.text;
  assert lib.hasInfix "_reconcile desired-resource-holds" holdActivation.text;
  assert lib.hasInfix "_reconcile hold apply" holdActivation.text;
  assert lib.hasInfix "/run/abird-host-agent-holds-ready" holdActivation.text;
  assert lib.hasInfix "abird-host-agent-generation-preflight" generationPreSwitchCheck;
  assert lib.hasInfix "abird-host-agent-generation-preflight --quiet" generationPreSwitchCheck;
  assert lib.hasInfix "abird-host-agent-generation-preflight" generationPreflightPackage.name;
  assert !(lib.hasInfix "abird-host-agent-service-placement-preflight" generationPreSwitchCheck);
  assert !(lib.hasInfix "abird-host-agent-projection-preflight" generationPreSwitchCheck);
  assert config.systemd.paths.abird-host-agent-jobs.pathConfig.PathChanged == "/var/lib/abird-host-agent/jobs-wakeup";
  assert config.systemd.services.abird-host-agent-jobs.unitConfig.ConditionPathExists == "/var/lib/abird-host-agent/jobs-wakeup";
  assert config.systemd.services.abird-host-agent-jobs.wantedBy == ["multi-user.target"];
  assert config.systemd.services.abird-host-agent-jobs.serviceConfig.Restart == "on-failure";
  assert lib.hasInfix "_reconcile jobs" config.systemd.services.abird-host-agent-jobs.serviceConfig.ExecStart;
  assert config.systemd.services.abird-host-agent-jobs.serviceConfig.TimeoutStartSec == "infinity";
  assert config.systemd.services.abird-host-agent-desired-resource-states.wantedBy == ["multi-user.target"];
  assert config.systemd.services.abird-host-agent-desired-resource-states.requires == ["abird-host-agent-holds.service"];
  assert builtins.elem "abird-host-agent-desired-resource-states.service" config.systemd.services.abird-host-agent-jobs.after;
  assert config.systemd.services.abird-host-agent-desired-resource-states.serviceConfig.Restart == "on-failure";
  assert lib.hasInfix "_reconcile desired-resource-states" config.systemd.services.abird-host-agent-desired-resource-states.serviceConfig.ExecStart;
  assert lib.hasInfix "--convergence-mode defer-held" config.systemd.services.abird-host-agent-desired-resource-states.serviceConfig.ExecStart;
  assert config.systemd.paths.abird-host-agent-desired-resource-states.pathConfig.PathChanged == "/etc/abird-host-agent/desired-resource-states.json";
  assert config.systemd.paths.abird-host-agent-desired-resource-states.pathConfig.Unit == "abird-host-agent-desired-resource-states.service";
  assert builtins.elem "d /var/lib/abird-host-agent/desired-resource-state-receipts 0700 root root -" config.systemd.tmpfiles.rules;
  assert builtins.elem "d /var/lib/abird-host-agent/desired-resource-state-deferrals 0700 root root -" config.systemd.tmpfiles.rules;
  assert builtins.elem "d /var/lib/abird-host-agent/activation-authorizations 0711 root root -" config.systemd.tmpfiles.rules;
  assert config.environment.etc."abird-host-agent/declared-holds/${holdFileName}".text == "${transaction}\n";
  assert !(builtins.hasAttr "abird-host-agent/declared-holds/${moveTargetHoldFileName}" config.environment.etc);
  assert desiredTargetDeclaration.state == "held";
  assert desiredTargetDeclaration.projection_id == transaction;
  assert desiredTargetDeclaration.projection_digest == projectionDigest;
    pkgs.runCommand "abird-host-agent-module-test" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      mkdir -p "$out"
      test -x ${runuserProgram}
      test -x ${configuredRoot}/bin/rsync
      test -x ${configuredRoot}/bin/tar
      grep -F -- ${lib.escapeShellArg "ABIRD_HOST_AGENT_RUNUSER"} ${configuredAgent}
      grep -F -- ${lib.escapeShellArg runuserProgram} ${configuredAgent}
      jq -e '.resources | any(.id == "service:demo" and .services[0].unit == "demo.service")' ${resourceManifest}
      jq -e '.rsync_program == "${pkgs.rsync}/bin/rsync" and .tar_program == "${pkgs.gnutar}/bin/tar"' ${resourceManifest}
      jq -e '.resources | any(.id == "${instanceResource}" and .data_paths == ["/var/lib/demo-instance"])' ${resourceManifest}
      jq -e '.resources | any(.id == "${extraResource}" and .operations.inspect.argv == ["${pkgs.coreutils}/bin/true", "--inspect"])' ${resourceManifest}
      jq -e '.resources | any(.id == "${resource}" and .file_states."route-target".expected_previous_sha256 == null and .file_states."route-target".accepted_previous_sha256 == ["${previousRouteDigest}"] and .file_states."route-target".validation_argv == ["${pkgs.coreutils}/bin/true", "--check-route"])' ${resourceManifest}
      jq -e '.resources | any(.id == "${hostResource}" and (.data_paths | index("/var/lib/demo")) != null and (.data_paths | index("/var/lib/demo-instance")) != null)' ${resourceManifest}
      jq -e '.schema_version == 1 and (.resources | any(.id == "${moveTargetResource}" and .state == "held" and .phase == "cutover" and .generation == 3 and .projection_digest == "${projectionDigest}" and .hold_epoch == "move:source-prepared"))' ${desiredResourceStateManifest}
      jq -e '.resources | any(.id == "${moveSourceResource}" and .state == "active" and .transaction_id == "move-demo--item-001" and .activation_job_id == "move-demo--item-001-cutover-activate-target" and .activation_requirement_digest == "${receiptRequirement}")' ${desiredResourceStateManifest}
      jq -e '.schema_version == 3 and .predecessors == {"1": {scope_aliases: {}}, "2": {scope_aliases: {}}} and .placements.abird.zulip == {migration_kind: "stateful", role: "corp"} and .moves == {}' ${servicePlacementAdmissionManifest}
      jq -e '.schema_version == 1 and .domains == [{name: "serviceMoves", schema_version: 1, adapter: "stateful-service-placement", authority_paths: ["service-placement-contract.json", "desired-resource-states.json", "resources.json"], program: .domains[0].program}] and (.domains[0].program | startswith("/nix/store/"))' ${generationAdmissionRegistryManifest}

      for generation in current same changed adopted adopted-source predecessor unregistered-predecessor invalid-predecessor downgraded rollback-downgraded reclassified missing-placement nonempty-predecessors changed-adapter changed-authority changed-schema-authority missing bootstrap partial-current empty-current multi-output new-current current-multi adopted-multi unregistered-current unregistered-changed unsafe-registry retired-domain duplicate-current duplicate-incoming; do
        mkdir -p "$generation/etc/abird-host-agent"
        cp ${desiredResourceStateManifest} "$generation/etc/abird-host-agent/desired-resource-states.json"
        cp ${resourceManifest} "$generation/etc/abird-host-agent/resources.json"
        cp ${generationAdmissionRegistryManifest} "$generation/etc/abird-host-agent/generation-admission-registry.json"
      done
      cp ${servicePlacementAdmissionManifest} current/etc/abird-host-agent/service-placement-contract.json
      cp ${servicePlacementAdmissionManifest} same/etc/abird-host-agent/service-placement-contract.json
      mkdir -p historical-resources/etc/abird-host-agent
      cp ${resourceManifest} historical-resources/etc/abird-host-agent/resources.json
      mkdir -p historical-desired/etc/abird-host-agent
      cp ${resourceManifest} historical-desired/etc/abird-host-agent/resources.json
      cp ${desiredResourceStateManifest} historical-desired/etc/abird-host-agent/desired-resource-states.json
      mkdir -p invalid-historical-desired/etc/abird-host-agent
      cp ${desiredResourceStateManifest} invalid-historical-desired/etc/abird-host-agent/desired-resource-states.json
      mkdir -p unregistered-predecessor-without-authority/etc/abird-host-agent
      preflight=${generationPreflightPackage}/bin/abird-host-agent-generation-preflight
      ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" --json "$PWD/same" switch \
        | jq -e '.operation == "host_agent_generation_preflight" and .result.checks == [{domain: "service-placement", status: "admitted"}, {domain: "desired-resource-state", status: "admitted", deferred_count: 0}] and (.result.domains[0].authority | map(.path) | sort) == ["desired-resource-states.json", "resources.json", "service-placement-contract.json"] and all(.result.domains[0].authority[]; (.incoming_sha256 | test("^[0-9a-f]{64}$")) and (.current_sha256 | test("^[0-9a-f]{64}$")))'
      human_output="$(ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/same" switch)"
      test "$human_output" = 'Generation admission: admitted (host=nixos, mode=normal, domains=1, deferred=0)'
      explicit_human_output="$(ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" --human "$PWD/same" switch)"
      test "$explicit_human_output" = "$human_output"
      quiet_output="$(ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" --quiet "$PWD/same" switch)"
      test -z "$quiet_output"
      ABIRD_HOST_AGENT_GENERATION_PREFLIGHT_OUTPUT=quiet \
        ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" \
        "$preflight" "$PWD/same" switch >environment-quiet-output
      test ! -s environment-quiet-output
      if "$preflight" --json --quiet "$PWD/same" switch; then
        echo "generation preflight accepted conflicting output modes" >&2
        exit 1
      fi
      if ABIRD_HOST_AGENT_GENERATION_PREFLIGHT_OUTPUT=invalid "$preflight" "$PWD/same" switch; then
        echo "generation preflight accepted an invalid environment output mode" >&2
        exit 1
      fi
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/same" boot; then
        echo "projection admission accepted a boot target that cannot be revalidated at reboot" >&2
        exit 1
      fi
      ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" --json "$PWD/same" dry-activate \
        | jq -e '.operation == "host_agent_generation_preflight" and .result.mode == "normal"'
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/historical-resources" "$preflight" "$PWD/same" switch; then
        echo "domain introduction admitted an incomplete predecessor authority set" >&2
        exit 1
      fi
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/historical-desired" "$preflight" "$PWD/same" switch; then
        echo "domain introduction admitted an incomplete predecessor authority prefix" >&2
        exit 1
      fi
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/historical-desired" "$preflight" "$PWD/same" switch rollback; then
        echo "rollback admitted a historical partial current authority prefix" >&2
        exit 1
      fi
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/invalid-historical-desired" "$preflight" "$PWD/same" switch; then
        echo "normal admission accepted desired-resource authority without its resource registry" >&2
        exit 1
      fi
      ABIRD_TEST_DEFERRED=1 ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" --json "$PWD/same" switch \
        | jq -e '.result.evidence == [{kind: "resource-deferred", domain: "desired-resource-state", host: "nixos", transaction_id: "move-demo--item-001", projection_id: "migration-test", resource: "service:move-source", status: "deferred-held", state: "active", generation: 3, reason: "activation_job_specification_conflict", detail: "terminal failed activation job differs"}]'
      if ABIRD_TEST_BAD_DEFERRED_COUNT=1 ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/same" switch; then
        echo "projection admission accepted contradictory deferred-resource totals" >&2
        exit 1
      fi
      for generation in duplicate-current duplicate-incoming; do
        cp ${servicePlacementAdmissionManifest} "$generation/etc/abird-host-agent/service-placement-contract.json"
        jq '.domains += [(.domains[0] | .name = "serviceMovesReplica")]' ${generationAdmissionRegistryManifest} >"$generation-registry.json"
        mv "$generation-registry.json" "$generation/etc/abird-host-agent/generation-admission-registry.json"
      done
      if ABIRD_TEST_DEFERRED=1 ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/duplicate-current" "$preflight" "$PWD/duplicate-incoming" switch; then
        echo "projection admission accepted duplicate deferred resources across domains" >&2
        exit 1
      fi
      cp ${servicePlacementAdmissionManifest} retired-domain/etc/abird-host-agent/service-placement-contract.json
      jq '.domains = []' ${generationAdmissionRegistryManifest} >retired-domain-registry.json
      mv retired-domain-registry.json retired-domain/etc/abird-host-agent/generation-admission-registry.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/retired-domain" switch; then
        echo "projection admission removed a durable domain tombstone" >&2
        exit 1
      fi
      jq '.placements.abird.zulip.role = "zulip"' ${servicePlacementAdmissionManifest} >changed/etc/abird-host-agent/service-placement-contract.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/changed" switch; then
        echo "unsafe stateful placement change was admitted" >&2
        exit 1
      fi
      jq '.placements.abird.zulip.role = "zulip" | .moves.move = {scope: "abird", services: ["zulip"], items: [{id: "item-001", service: "zulip", from: "corp", to: "zulip", basis_sha256: "${projectionDigest}"}], phase: "adopting-target", decision: "complete", basis_sha256: "${projectionDigest}", semantic_sha256: "${projectionDigest}", projection_sha256: "${projectionDigest}"}' ${servicePlacementAdmissionManifest} >adopted/etc/abird-host-agent/service-placement-contract.json
      ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/adopted" switch >/dev/null
      jq '.placements.abird.zulip.role = "zulip" | .moves.move = {scope: "abird", services: ["zulip"], items: [{id: "item-001", service: "zulip", from: "zulip", to: "corp", basis_sha256: "${projectionDigest}"}], phase: "adopting-source", decision: "rollback", basis_sha256: "${projectionDigest}", semantic_sha256: "${projectionDigest}", projection_sha256: "${projectionDigest}"}' ${servicePlacementAdmissionManifest} >adopted-source/etc/abird-host-agent/service-placement-contract.json
      ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/adopted-source" switch >/dev/null
      jq '.placements.abird.mail = {migration_kind: "stateful", role: "corp"}' ${servicePlacementAdmissionManifest} >current-multi/etc/abird-host-agent/service-placement-contract.json
      jq '.placements.abird.zulip.role = "zulip"
          | .placements.abird.mail.role = "zulip"
          | .moves.move = {
              scope: "abird",
              services: ["zulip", "mail"],
              items: [
                {id: "item-001", service: "zulip", from: "corp", to: "zulip", basis_sha256: "${projectionDigest}"},
                {id: "item-002", service: "mail", from: "corp", to: "zulip", basis_sha256: "${previousRouteDigest}"}
              ],
              phase: "adopting-target",
              decision: "complete",
              basis_sha256: "${projectionDigest}",
              semantic_sha256: "${projectionDigest}",
              projection_sha256: "${projectionDigest}"
            }' current-multi/etc/abird-host-agent/service-placement-contract.json >adopted-multi/etc/abird-host-agent/service-placement-contract.json
      ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current-multi" "$preflight" "$PWD/adopted-multi" switch >/dev/null
      jq '.moves.move = {scope: "abird", services: ["zulip"], items: [{id: "item-001", service: "zulip", from: "corp", to: "zulip", basis_sha256: "${projectionDigest}"}], phase: "target-active", decision: null, basis_sha256: "${projectionDigest}", semantic_sha256: "${projectionDigest}", projection_sha256: "${projectionDigest}"}' ${servicePlacementAdmissionManifest} >predecessor/etc/abird-host-agent/service-placement-contract.json
      ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/adopted" "$preflight" "$PWD/predecessor" switch rollback >/dev/null
      cp predecessor/etc/abird-host-agent/service-placement-contract.json unregistered-predecessor/etc/abird-host-agent/service-placement-contract.json
      rm unregistered-predecessor/etc/abird-host-agent/generation-admission-registry.json
      ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/adopted" "$preflight" --json "$PWD/unregistered-predecessor" switch rollback \
        | jq -e '(.result.domains | map(del(.authority))) == [{schema_version: 1, domain: "serviceMoves", adapter: "stateful-service-placement", mode: "rollback", transition: "removed", host: "nixos", checks: [{domain: "service-placement", status: "admitted"}, {domain: "desired-resource-state", status: "admitted", deferred_count: 0}], evidence: [], deferred_resources: {count: 0, resources: []}}] and (.result.domains[0].authority | length) == 3'
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/unregistered-predecessor-without-authority" switch rollback; then
        echo "rollback admitted a predecessor before its domain authority was staged" >&2
        exit 1
      fi
      jq '.moves.move.projection_sha256 = "${previousRouteDigest}"' predecessor/etc/abird-host-agent/service-placement-contract.json >invalid-predecessor/etc/abird-host-agent/service-placement-contract.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/adopted" "$preflight" "$PWD/invalid-predecessor" switch rollback; then
        echo "unrelated stateful placement predecessor was admitted for rollback" >&2
        exit 1
      fi
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/missing" switch; then
        echo "placement admission contract removal was admitted" >&2
        exit 1
      fi
      jq '.schema_version = 1' ${servicePlacementAdmissionManifest} >downgraded/etc/abird-host-agent/service-placement-contract.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/downgraded" switch; then
        echo "service-placement schema downgrade was admitted" >&2
        exit 1
      fi
      cp downgraded/etc/abird-host-agent/service-placement-contract.json rollback-downgraded/etc/abird-host-agent/service-placement-contract.json
      rm rollback-downgraded/etc/abird-host-agent/generation-admission-registry.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/rollback-downgraded" switch rollback; then
        echo "rollback admitted a retired service-placement schema" >&2
        exit 1
      fi
      cp ${servicePlacementAdmissionManifest} changed-adapter/etc/abird-host-agent/service-placement-contract.json
      jq '.domains[0].adapter = "replacement-adapter"' ${generationAdmissionRegistryManifest} >changed-adapter-registry.json
      mv changed-adapter-registry.json changed-adapter/etc/abird-host-agent/generation-admission-registry.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/changed-adapter" switch; then
        echo "projection adapter replacement was admitted without a domain migration" >&2
        exit 1
      fi
      cp ${servicePlacementAdmissionManifest} changed-authority/etc/abird-host-agent/service-placement-contract.json
      jq '.domains[0].authority_paths = ["service-placement-contract.json", "resources.json"]' ${generationAdmissionRegistryManifest} >changed-authority-registry.json
      mv changed-authority-registry.json changed-authority/etc/abird-host-agent/generation-admission-registry.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/changed-authority" switch; then
        echo "projection authority replacement was admitted without a domain migration" >&2
        exit 1
      fi
      cp ${servicePlacementAdmissionManifest} changed-schema-authority/etc/abird-host-agent/service-placement-contract.json
      jq '.domains[0].schema_version = 2 | .domains[0].authority_paths = ["service-placement-contract.json", "resources.json"]' ${generationAdmissionRegistryManifest} >changed-schema-authority-registry.json
      mv changed-schema-authority-registry.json changed-schema-authority/etc/abird-host-agent/generation-admission-registry.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/changed-schema-authority" switch; then
        echo "projection authority replacement was admitted through an unsupported schema bump" >&2
        exit 1
      fi
      jq '.placements.abird.zulip.migration_kind = "stateless"' ${servicePlacementAdmissionManifest} >reclassified/etc/abird-host-agent/service-placement-contract.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/reclassified" switch; then
        echo "loss of established stateful classification was admitted" >&2
        exit 1
      fi
      jq 'del(.placements.abird.zulip)' ${servicePlacementAdmissionManifest} >missing-placement/etc/abird-host-agent/service-placement-contract.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/missing-placement" switch; then
        echo "loss of established stateful placement was admitted" >&2
        exit 1
      fi
      jq '.predecessors."1".scope_aliases.abird = "abird-gondor"' ${servicePlacementAdmissionManifest} >nonempty-predecessors/etc/abird-host-agent/service-placement-contract.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/nonempty-predecessors" switch; then
        echo "retired predecessor mapping was admitted" >&2
        exit 1
      fi
      jq 'del(.placements.abird.zulip)' ${servicePlacementAdmissionManifest} >new-current/etc/abird-host-agent/service-placement-contract.json
      ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/new-current" "$preflight" "$PWD/same" switch >/dev/null
      cp ${servicePlacementAdmissionManifest} bootstrap/etc/abird-host-agent/service-placement-contract.json
      cp ${servicePlacementAdmissionManifest} unregistered-current/etc/abird-host-agent/service-placement-contract.json
      rm unregistered-current/etc/abird-host-agent/generation-admission-registry.json
      ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/unregistered-current" "$preflight" "$PWD/same" switch >/dev/null
      cp ${servicePlacementAdmissionManifest} unregistered-changed/etc/abird-host-agent/service-placement-contract.json
      rm unregistered-changed/etc/abird-host-agent/generation-admission-registry.json
      jq '.configuration_revision = "unregistered-revision"' ${resourceManifest} >unregistered-resources.json
      mv unregistered-resources.json unregistered-changed/etc/abird-host-agent/resources.json
      ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/unregistered-changed" "$preflight" "$PWD/same" switch >/dev/null
      mkdir -p bootstrap-current
      ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/bootstrap-current" "$preflight" "$PWD/bootstrap" switch >/dev/null
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/bootstrap-current" "$preflight" "$PWD/bootstrap" switch rollback; then
        echo "rollback without complete current generation authority was admitted" >&2
        exit 1
      fi
      rm partial-current/etc/abird-host-agent/desired-resource-states.json partial-current/etc/abird-host-agent/resources.json
      cp ${servicePlacementAdmissionManifest} partial-current/etc/abird-host-agent/service-placement-contract.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/partial-current" "$preflight" "$PWD/bootstrap" switch; then
        echo "normal admission accepted partial current generation authority" >&2
        exit 1
      fi
      rm -f empty-current/etc/abird-host-agent/desired-resource-states.json empty-current/etc/abird-host-agent/resources.json empty-current/etc/abird-host-agent/service-placement-contract.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/empty-current" "$preflight" "$PWD/bootstrap" switch; then
        echo "normal admission accepted a current registry without its authority" >&2
        exit 1
      fi
      cp ${servicePlacementAdmissionManifest} multi-output/etc/abird-host-agent/service-placement-contract.json
      admission_program=$(jq -r '.domains[0].program' ${generationAdmissionRegistryManifest})
      multi_output_program="$out/multi-output-admission"
      {
        printf '%s\n' '#!${pkgs.runtimeShell}'
        printf '%s\n' "printf '{}\\n'"
        printf 'exec %q "$@"\n' "$admission_program"
      } >"$multi_output_program"
      chmod +x "$multi_output_program"
      jq --arg program "$multi_output_program" '.domains[0].program = $program' ${generationAdmissionRegistryManifest} >multi-output-registry.json
      mv multi-output-registry.json multi-output/etc/abird-host-agent/generation-admission-registry.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/multi-output" switch; then
        echo "projection admission accepted multiple adapter documents" >&2
        exit 1
      fi

      cp ${servicePlacementAdmissionManifest} unsafe-registry/etc/abird-host-agent/service-placement-contract.json
      jq '.domains[0].authority_paths = [".git/authority.json"]' ${generationAdmissionRegistryManifest} >unsafe-registry.json
      mv unsafe-registry.json unsafe-registry/etc/abird-host-agent/generation-admission-registry.json
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$PWD/unsafe-registry" switch; then
        echo "projection admission accepted a Git metadata authority path" >&2
        exit 1
      fi

      grep -F -- 'incoming generation is missing the projection admission registry' "$preflight"
      grep -F -- '--require-complete-authority' "$admission_program"
      incoming="$TMPDIR/incoming"
      mkdir -p "$incoming/etc/abird-host-agent"
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$incoming" switch; then
        echo "projection preflight accepted missing manifests" >&2
        exit 1
      fi
      cp ${generationAdmissionRegistryManifest} "$incoming/etc/abird-host-agent/generation-admission-registry.json"
      cp ${resourceManifest} "$incoming/etc/abird-host-agent/resources.json"
      cp ${servicePlacementAdmissionManifest} "$incoming/etc/abird-host-agent/service-placement-contract.json"
      if ABIRD_HOST_AGENT_CURRENT_SYSTEM="$PWD/current" "$preflight" "$incoming" switch; then
        echo "projection preflight accepted a missing desired-state manifest" >&2
        exit 1
      fi

    ''
