{pkgs}: let
  lib = pkgs.lib;
  fakeAgent = pkgs.writeShellScriptBin "abird-host-agent" ''
    exit 0
  '';
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
  config = evalConfig.config;
  conditions = [
    "|!${holdFile}"
    "|${activationAuthorization resource}"
    "!${hostHoldFile}"
  ];
  holdCommands = config.systemd.services.abird-host-agent-holds.serviceConfig.ExecStart;
  holdActivation = config.system.activationScripts.abird-host-agent-holds;
  projectionPreSwitchCheck = config.system.preSwitchChecks.abird-host-agent-projection;
  projectionPreflightPackage = builtins.head (lib.filter (package: lib.hasInfix "abird-host-agent-projection-preflight" package.name) config.environment.systemPackages);
  configuredAgent = builtins.head (lib.splitString " " config.systemd.services.abird-host-agent-jobs.serviceConfig.ExecStart);
  configuredRoot = builtins.dirOf (builtins.dirOf configuredAgent);
  resourceManifest = config.environment.etc."abird-host-agent/resources.json".source;
  desiredResourceStateManifest = config.environment.etc."abird-host-agent/desired-resource-states.json".source;
  desiredTargetDeclaration = builtins.fromJSON config.environment.etc."abird-host-agent/desired-resource-states/${moveTargetHoldFileName}".text;
  runuserProgram = lib.getExe' pkgs.util-linux "runuser";
in
  assert !collisionResult.success;
  assert !rootPathResult.success;
  assert !unnamedUserResult.success;
  assert !missingUserUidResult.success;
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
  assert lib.hasInfix "abird-host-agent-projection-preflight" projectionPreSwitchCheck;
  assert lib.hasInfix "abird-host-agent-projection-preflight" projectionPreflightPackage.name;
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

      preflight=${projectionPreflightPackage}/bin/abird-host-agent-projection-preflight
      grep -F -- 'incoming system path is missing host-agent projection authority' "$preflight"
      grep -F -- '--require-complete-authority' "$preflight"
      incoming="$TMPDIR/incoming"
      mkdir -p "$incoming/etc/abird-host-agent"
      if "$preflight" "$incoming" switch; then
        echo "projection preflight accepted missing manifests" >&2
        exit 1
      fi
      touch "$incoming/etc/abird-host-agent/resources.json"
      if "$preflight" "$incoming" switch; then
        echo "projection preflight accepted a missing desired-state manifest" >&2
        exit 1
      fi
      touch "$incoming/etc/abird-host-agent/desired-resource-states.json"
      "$preflight" "$incoming" switch rollback

      touch "$out"
    ''
