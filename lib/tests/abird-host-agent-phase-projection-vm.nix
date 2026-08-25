{pkgs}: let
  lib = pkgs.lib;
  intentDigest = builtins.concatStringsSep "" (lib.replicate 64 "a");
  requirementDigest = builtins.concatStringsSep "" (lib.replicate 64 "b");
  heldProjectionDigest = builtins.concatStringsSep "" (lib.replicate 64 "1");
  activeProjectionDigest = builtins.concatStringsSep "" (lib.replicate 64 "2");
  projectionId = "move-vm";
  resources = ["service:deploy-first" "service:controller-first"];
  userHeldResource = "service:user-held";
  identityFor = resource: let
    name = lib.removePrefix "service:" resource;
    transactionId = "${projectionId}--${name}";
  in {
    inherit name transactionId;
    jobId = "${transactionId}-cutover-activate-target";
    holdEpoch = "${name}:target-pre-cutover";
  };
  desiredFor = state: generation: projectionDigest: resource: let
    identity = identityFor resource;
  in {
    inherit state generation;
    projectionId = projectionId;
    intentDigest = intentDigest;
    phase =
      if state == "active"
      then "cutover"
      else "prepared";
    projectionDigest = projectionDigest;
    holdEpoch = identity.holdEpoch;
    transactionId = identity.transactionId;
    activationJobId =
      if state == "active"
      then identity.jobId
      else null;
    activationRequirementKind = "prepared_receipt";
    activationRequirementDigest = requirementDigest;
  };
  activeManifest = pkgs.writeText "phase-projection-active.json" (builtins.toJSON {
    schema_version = 1;
    resources =
      map (resource: let
        desired = desiredFor "active" 2 activeProjectionDigest resource;
      in {
        id = resource;
        state = desired.state;
        projection_id = desired.projectionId;
        intent_digest = desired.intentDigest;
        phase = desired.phase;
        projection_digest = desired.projectionDigest;
        generation = desired.generation;
        hold_epoch = desired.holdEpoch;
        transaction_id = desired.transactionId;
        activation_job_id = desired.activationJobId;
        activation_requirement_kind = desired.activationRequirementKind;
        activation_requirement_digest = desired.activationRequirementDigest;
      })
      resources;
  });
  projectionBinding = builtins.toJSON {
    intent_digest = intentDigest;
    projection_digest = activeProjectionDigest;
    generation = 2;
    activation_requirement_digest = requirementDigest;
  };
  materialize = resource: let
    identity = identityFor resource;
    binding = builtins.toJSON ((builtins.fromJSON projectionBinding)
      // {
        hold_epoch = identity.holdEpoch;
      });
  in
    pkgs.writeShellScript "materialize-${identity.name}-activation" ''
      exec abird-host-agent --json job _materialize \
        --job-id ${lib.escapeShellArg identity.jobId} \
        --transaction ${lib.escapeShellArg identity.transactionId} \
        --resource ${lib.escapeShellArg resource} \
        --projection ${lib.escapeShellArg binding} \
        --operation activate
    '';
in
  pkgs.testers.runNixOSTest {
    name = "abird-host-agent-phase-projection-mixed-issuers";

    nodes.machine = {pkgs, ...}: {
      imports = [../services/abird-host-agent];

      services.abird-host-agent = {
        enable = true;
        package = pkgs.abird-host-agent;
        manageHostResource = false;
        desiredResourceStates =
          lib.genAttrs resources (
            desiredFor "held" 1 heldProjectionDigest
          )
          // {
            ${userHeldResource} = desiredFor "held" 1 heldProjectionDigest userHeldResource;
          };
        services = {
          deploy-first.units = [{unit = "deploy-first.service";}];
          controller-first.units = [{unit = "controller-first.service";}];
          user-held.units = [
            {
              scope = "user";
              user = "operator";
              unit = "user-held.service";
            }
          ];
        };
      };

      systemd.services = {
        deploy-first.serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
        controller-first.serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      };
      systemd.user.services.user-held = {
        wantedBy = ["default.target"];
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        };
      };

      users.users.operator = {
        isNormalUser = true;
        uid = 1000;
        linger = true;
      };

      environment.systemPackages = [pkgs.jq];
      system.stateVersion = "26.05";
    };

    testScript = ''
      start_all()
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("abird-host-agent-holds.service")
      machine.succeed("systemctl is-active abird-host-agent-holds.service")
      machine.succeed("systemctl show -p Result --value abird-host-agent-desired-resource-states.service | grep -Fx success")
      machine.succeed("systemctl show -p ExecMainStartTimestampMonotonic --value abird-host-agent-desired-resource-states.service | grep -E '^[1-9][0-9]*$'")
      machine.wait_for_unit("user@1000.service")
      machine.succeed("systemctl --user -M operator@ start user-held.service")
      machine.fail("systemctl --user -M operator@ is-active user-held.service")

      for unit in ["deploy-first.service", "controller-first.service"]:
          machine.succeed(f"systemctl start {unit}")
          machine.fail(f"systemctl is-active {unit}")

      # Controller-first: submit and execute the canonical job before deploy
      # desired-state reconciliation sees the active generation.
      machine.succeed("${materialize "service:controller-first"} | jq -e '.result.spec' > /tmp/controller-first.json")
      machine.succeed("abird-host-agent --json job submit --spec /tmp/controller-first.json | jq -e '.result.job.status == \"succeeded\"'")
      machine.wait_for_unit("controller-first.service")

      # The deploy reconciler adopts that job and creates the deploy-first job.
      machine.succeed("abird-host-agent --json _reconcile desired-resource-states --manifest ${activeManifest} | jq -e '.result.count == 2'")
      machine.wait_for_unit("deploy-first.service")

      # Controller-after-deploy submits the identical deploy-first spec and
      # attaches to its already-succeeded record.
      machine.succeed("${materialize "service:deploy-first"} | jq -e '.result.spec' > /tmp/deploy-first.json")
      machine.succeed("abird-host-agent --json job submit --spec /tmp/deploy-first.json | jq -e '.result.changed == false and .result.job.status == \"succeeded\"'")

      for job in [
          "move-vm--deploy-first-cutover-activate-target",
          "move-vm--controller-first-cutover-activate-target",
      ]:
          machine.succeed(f"abird-host-agent --json job status --job-id {job} | jq -e '.result.status == \"succeeded\" and .result.attempts == 1'")

      machine.succeed("systemctl is-active deploy-first.service controller-first.service")
    '';
  }
