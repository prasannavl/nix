{
  config,
  lib,
  pkgs,
  specialArgs,
  ...
}: let
  cfg = config.services.abird-host-agent;
  phaseProjection = import ./phase-projection.nix {lib = lib;};
  runuserProgram = lib.getExe' pkgs.util-linux "runuser";
  systemctlProgram = pkgs.writeShellApplication {
    name = "abird-host-agent-systemctl";
    runtimeInputs = [pkgs.coreutils pkgs.systemd pkgs.util-linux];
    text = builtins.readFile ./systemctl.sh;
  };
  normalizeManagedResource = resource:
    builtins.removeAttrs resource ["units"]
    // {
      services = resource.units;
    };
  serviceResources =
    lib.mapAttrs' (
      name: resource:
        lib.nameValuePair "service:${name}" (normalizeManagedResource resource)
    )
    cfg.services;
  instanceResources =
    lib.mapAttrs' (
      name: resource:
        lib.nameValuePair "instance:${name}" (normalizeManagedResource resource)
    )
    cfg.instances;
  typedResources = serviceResources // instanceResources;
  typedResourceNames = builtins.attrNames cfg.services ++ builtins.attrNames cfg.instances;
  resourceIdCollisions = lib.intersectLists (builtins.attrNames cfg.extraResources) (builtins.attrNames typedResources);
  declaredResourcesById = cfg.extraResources // typedResources;
  declaredResources = builtins.attrValues declaredResourcesById;
  effectivePhaseProjections = (specialArgs.phaseProjections or []) ++ cfg.phaseProjections;
  projectedResourceStateSets = map (projection:
    phaseProjection.localDesiredResourceStates {
      hostResource = "host:${config.networking.hostName}";
      projection = projection;
    })
  effectivePhaseProjections;
  phaseProjectionIds = map (projection: projection.projection_id) effectivePhaseProjections;
  projectedResourceStateNames = lib.concatMap builtins.attrNames projectedResourceStateSets;
  projectedResourceStates = lib.foldl' (states: projected: states // projected) {} projectedResourceStateSets;
  effectiveDesiredResourceStates = projectedResourceStates // cfg.desiredResourceStates;
  desiredResourceStateNames = builtins.attrNames effectiveDesiredResourceStates;
  declaredGatedUsers = lib.unique (lib.concatMap (resource:
    builtins.attrNames resource.gatedUserUnits
    ++ map (service: service.user) (builtins.filter (service: service.scope == "user" && service.user != null) resource.services))
  declaredResources);
  gatedUserIds = lib.genAttrs declaredGatedUsers (
    user: lib.attrByPath [user "uid"] null config.users.users
  );
  gatedUserManagerUnits =
    lib.concatMap (
      user: let
        uid = gatedUserIds.${user};
      in
        lib.optional (builtins.isInt uid) "user@${toString uid}.service"
    )
    declaredGatedUsers;
  userHoldReadyUnit = "abird-host-agent-holds-ready.service";
  userHoldReadyGeneration = builtins.substring 0 16 (builtins.hashString "sha256" (builtins.unsafeDiscardStringContext "${resourceManifest}\n${desiredResourceStateManifest}\n${builtins.toJSON effectiveDeclaredHolds}"));
  userHoldReadyMarker = "/run/abird-host-agent-holds-ready-${userHoldReadyGeneration}";
  waitForUserHoldReady = pkgs.writeShellScript "abird-host-agent-wait-for-holds" ''
    set -eu
    while [ ! -e ${lib.escapeShellArg userHoldReadyMarker} ]; do
      ${pkgs.coreutils}/bin/sleep 0.1
    done
  '';
  compactPaths = paths: let
    uniquePaths = lib.unique paths;
  in
    builtins.filter
    (path: !lib.any (parent: parent != path && lib.hasPrefix "${parent}/" path) uniquePaths)
    uniquePaths;
  hostResourceId = "host:${config.networking.hostName}";
  hostResource = {
    services = lib.unique (lib.concatMap (resource: resource.services) declaredResources);
    dataPaths = compactPaths (cfg.hostDataPaths ++ lib.concatMap (resource: resource.dataPaths) declaredResources);
    dataRoots = lib.listToAttrs (lib.concatLists (lib.mapAttrsToList (resourceId: resource:
      lib.mapAttrsToList (name: root:
        lib.nameValuePair "${builtins.hashString "sha256" resourceId}-${name}" root)
      resource.dataRoots)
    declaredResourcesById));
    backupConsistency = "quiesced";
    operations = {};
    readiness = [];
    transfers = {};
    fileStates = {};
    instances = {};
    deployments = {};
    gatedSystemUnits = lib.unique (lib.concatMap (resource: resource.gatedSystemUnits) declaredResources);
    gatedUserUnits = lib.genAttrs declaredGatedUsers (user: lib.unique (lib.concatMap (resource: resource.gatedUserUnits.${user} or []) declaredResources));
  };
  effectiveResources =
    declaredResourcesById
    // lib.optionalAttrs (cfg.manageHostResource && !builtins.hasAttr hostResourceId declaredResourcesById && (hostResource.services != [] || hostResource.dataPaths != [] || hostResource.dataRoots != {})) {
      ${hostResourceId} = hostResource;
    };
  nixbotDeployEnabled = cfg.nixbotDeploy.enable;
  nixbotRepository = config.services.nixbot.repos.${cfg.nixbotDeploy.repository};
  nixbotIdentityFiles = config.services.nixbot.sshClient.identityFiles;
  opensshEd25519HostKeys = builtins.filter (key: key.type == "ed25519") config.services.openssh.hostKeys;
  sshHostEd25519PublicKey =
    if cfg.sshHostEd25519PublicKey != null
    then cfg.sshHostEd25519PublicKey
    else if opensshEd25519HostKeys != []
    then "${(builtins.head opensshEd25519HostKeys).path}.pub"
    else "/etc/ssh/ssh_host_ed25519_key.pub";
  effectiveBrokerTransfer =
    if cfg.brokerTransfer != null
    then cfg.brokerTransfer
    else if nixbotDeployEnabled
    then {
      identityFile = builtins.head nixbotIdentityFiles;
      sshProgram = "${pkgs.openssh}/bin/ssh";
      sshAgentProgram = "${pkgs.openssh}/bin/ssh-agent";
      sshAddProgram = "${pkgs.openssh}/bin/ssh-add";
      sshArgs = [
        "-F"
        config.services.nixbot.sshClient.configPath
      ];
    }
    else null;
  holdFileName = resource: "${builtins.hashString "sha256" resource}.json";
  validServiceTarget = service:
    if service.scope == "user"
    then service.user != null && service.user != ""
    else service.user == null;
  validDataRoot = name: root:
    builtins.match "[A-Za-z0-9._-]+" name
    != null
    && lib.hasPrefix "/" root.path
    && root.path != "/"
    && lib.all (exclude:
      exclude
      != ""
      && !lib.hasPrefix "/" exclude
      && lib.all (component: component != "" && component != "." && component != "..") (lib.splitString "/" exclude))
    root.excludes;
  holdFile = resource: "${cfg.stateDirectory}/holds/${holdFileName resource}";
  activationAuthorization = resource: "${cfg.stateDirectory}/activation-authorizations/${builtins.hashString "sha256" resource}.json";
  desiredStateDocument = resource: desired: {
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
  };
  projectedHoldResources = builtins.attrNames (
    lib.filterAttrs (_: desired: desired.holdEpoch != null) effectiveDesiredResourceStates
  );
  declaredProjectedHoldCollisions = lib.intersectLists (builtins.attrNames cfg.declaredHolds) projectedHoldResources;
  effectiveDeclaredHolds = cfg.declaredHolds;
  configuredPackage = pkgs.symlinkJoin {
    name = "abird-host-agent-configured";
    paths = [cfg.package];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      ln -sfn ${lib.escapeShellArg cfg.rsyncProgram} "$out/bin/rsync"
      ln -sfn ${lib.escapeShellArg cfg.tarProgram} "$out/bin/tar"
      wrapProgram "$out/bin/abird-host-agent" \
        --set ABIRD_HOST_AGENT_STATE_DIR ${lib.escapeShellArg cfg.stateDirectory} \
        --set ABIRD_HOST_AGENT_RESOURCE_MANIFEST ${lib.escapeShellArg cfg.manifestPath} \
        --set ABIRD_HOST_AGENT_SYSTEMCTL ${lib.escapeShellArg (lib.getExe systemctlProgram)} \
        --set ABIRD_HOST_AGENT_JOURNALCTL ${lib.escapeShellArg "${pkgs.systemd}/bin/journalctl"} \
        --set ABIRD_HOST_AGENT_RUNUSER ${lib.escapeShellArg runuserProgram} \
        --set ABIRD_HOST_AGENT_PODMAN ${lib.escapeShellArg "${pkgs.podman}/bin/podman"} \
        --set ABIRD_HOST_AGENT_NIX_COLLECT_GARBAGE ${lib.escapeShellArg "${pkgs.nix}/bin/nix-collect-garbage"} \
        --set ABIRD_HOST_AGENT_SSH_HOST_ED25519_PUBLIC_KEY ${lib.escapeShellArg sshHostEd25519PublicKey}
    '';
  };
  resourceManifest = pkgs.writeText "abird-host-agent-resources.json" (builtins.toJSON {
    schema_version = 1;
    backup_root = cfg.backupRoot;
    rsync_program = cfg.rsyncProgram;
    tar_program = cfg.tarProgram;
    broker_transfer =
      if effectiveBrokerTransfer == null
      then null
      else {
        identity_file = effectiveBrokerTransfer.identityFile;
        ssh_program = effectiveBrokerTransfer.sshProgram;
        ssh_agent_program = effectiveBrokerTransfer.sshAgentProgram;
        ssh_add_program = effectiveBrokerTransfer.sshAddProgram;
        ssh_args = effectiveBrokerTransfer.sshArgs;
      };
    nixbot_deploy =
      if !nixbotDeployEnabled
      then null
      else {
        program = "${config.services.nixbot.package}/bin/nixbot";
        runuser_program = runuserProgram;
        env_program = "${pkgs.coreutils}/bin/env";
        user = config.services.nixbot.user.name;
        home = config.services.nixbot.stateDir;
        repository_url = nixbotRepository.url;
        repository_path = nixbotRepository.path;
        repository_ssh_key_paths = nixbotRepository.sshIdentityFiles;
        config_override_path = cfg.nixbotDeploy.configOverride;
        revision =
          if config.system.configurationRevision == null
          then "UNCOMMITTED-CONTROLLER-GENERATION"
          else config.system.configurationRevision;
      };
    resources =
      lib.mapAttrsToList (id: resource: {
        id = id;
        services = resource.services;
        data_paths = compactPaths resource.dataPaths;
        data_roots =
          lib.mapAttrsToList (name: root: {
            inherit name;
            inherit (root) path excludes;
          })
          resource.dataRoots;
        backup_consistency = resource.backupConsistency;
        operations = lib.mapAttrs (_: argv: {argv = argv;}) resource.operations;
        readiness =
          map
          (check:
            if check.type == "path"
            then {
              type = "path";
              inherit (check) path requirement;
            }
            else if check.type == "tcp"
            then {
              type = "tcp";
              inherit (check) address;
              timeout_ms = check.timeoutMs;
            }
            else {
              type = "http";
              inherit (check) address host;
              path = check.httpPath;
              expected_statuses = check.expectedStatuses;
              timeout_ms = check.timeoutMs;
            })
          resource.readiness;
        transfers =
          lib.mapAttrs (_: transfer: {
            inherit (transfer) source destination delete;
            rsync_program = transfer.rsyncProgram;
            tar_program = transfer.tarProgram;
            fallback_copy = transfer.fallbackCopy;
            remote_source =
              if transfer.remoteSource == null
              then null
              else {
                inherit (transfer.remoteSource) host user port;
                identity_file = transfer.remoteSource.identityFile;
                ssh_program = transfer.remoteSource.sshProgram;
                ssh_args = transfer.remoteSource.sshArgs;
                agent_program = transfer.remoteSource.agentProgram;
                agent_prefix = transfer.remoteSource.agentPrefix;
                rsync_program = transfer.remoteSource.rsyncProgram;
                rsync_prefix = transfer.remoteSource.rsyncPrefix;
                tar_program = transfer.remoteSource.tarProgram;
              };
          })
          resource.transfers;
        file_states =
          lib.mapAttrs (_: state: {
            inherit (state) path content mode;
            expected_previous_sha256 = state.expectedPreviousSha256;
            accepted_previous_sha256 = state.acceptedPreviousSha256;
            validation_argv = state.validationArgv;
            reload_services = state.reloadServices;
          })
          resource.fileStates;
        instances =
          lib.mapAttrs (_: instance: {
            inherit (instance) program name image project profiles config devices start;
          })
          resource.instances;
        deployments =
          lib.mapAttrs (_: deployment: {
            inherit (deployment) system mode;
          })
          resource.deployments;
        nixbot_deploy = false;
      })
      effectiveResources
      ++ lib.optional nixbotDeployEnabled {
        id = "controller:nixbot";
        services = [];
        data_paths = [];
        data_roots = [];
        backup_consistency = "live";
        operations = {};
        readiness = [];
        transfers = {};
        file_states = {};
        instances = {};
        deployments = {};
        nixbot_deploy = true;
      };
  });
  desiredResourceStateManifest = pkgs.writeText "abird-host-agent-desired-resource-states.json" (builtins.toJSON {
    schema_version = 1;
    resources =
      lib.mapAttrsToList
      desiredStateDocument
      effectiveDesiredResourceStates;
  });
  # An unheld resource starts normally. A held resource starts only while the
  # host agent has installed its stable, exact-evidence capability. The agent
  # clears that capability whenever any new hold is acquired.
  conditionsFor = resource:
    if resource == hostResourceId
    then ["!${holdFile resource}"]
    else [
      "|!${holdFile resource}"
      "|${activationAuthorization resource}"
    ];
  systemServicesFor = spec:
    lib.unique (
      map
      (service: service.unit)
      (builtins.filter (
          service: service.scope == "system" && lib.hasSuffix ".service" service.unit
        )
        spec.services)
      ++ builtins.filter (unit: lib.hasSuffix ".service" unit) spec.gatedSystemUnits
    );
  systemTargetsFor = spec:
    lib.unique (
      map
      (service: service.unit)
      (builtins.filter (
          service: service.scope == "system" && lib.hasSuffix ".target" service.unit
        )
        spec.services)
      ++ builtins.filter (unit: lib.hasSuffix ".target" unit) spec.gatedSystemUnits
    );
  userServicesFor = user: spec:
    lib.unique (
      map
      (service: service.unit)
      (builtins.filter (
          service:
            service.scope
            == "user"
            && service.user == user
            && lib.hasSuffix ".service" service.unit
        )
        spec.services)
      ++ builtins.filter (unit: lib.hasSuffix ".service" unit) (spec.gatedUserUnits.${user} or [])
    );
  userTargetsFor = user: spec:
    lib.unique (
      map
      (service: service.unit)
      (builtins.filter (
          service:
            service.scope
            == "user"
            && service.user == user
            && lib.hasSuffix ".target" service.unit
        )
        spec.services)
      ++ builtins.filter (unit: lib.hasSuffix ".target" unit) (spec.gatedUserUnits.${user} or [])
    );
  userNamesFor = spec:
    lib.unique (
      map
      (service: service.user)
      (builtins.filter (service: service.scope == "user" && service.user != null) spec.services)
      ++ builtins.attrNames spec.gatedUserUnits
    );
  userServiceNames = lib.unique (lib.concatMap (spec:
    lib.concatMap (user: userServicesFor user spec) (userNamesFor spec))
  (builtins.attrValues effectiveResources));
  userTargetNames = lib.unique (lib.concatMap (spec:
    lib.concatMap (user: userTargetsFor user spec) (userNamesFor spec))
  (builtins.attrValues effectiveResources));
  userReadinessServiceGates = lib.genAttrs (map (lib.removeSuffix ".service") userServiceNames) (_: {
    after = [userHoldReadyUnit];
    requires = [userHoldReadyUnit];
  });
  userReadinessTargetGates = lib.genAttrs (map (lib.removeSuffix ".target") userTargetNames) (_: {
    after = [userHoldReadyUnit];
    requires = [userHoldReadyUnit];
  });
  mkSystemServiceGates = resource: spec:
    lib.listToAttrs (
      map
      (unit: {
        name = lib.removeSuffix ".service" unit;
        value = {
          after = ["abird-host-agent-holds.service"];
          requires = ["abird-host-agent-holds.service"];
          unitConfig.ConditionPathExists = conditionsFor resource;
        };
      })
      (systemServicesFor spec)
    );
  mkSystemTargetGates = resource: spec:
    lib.listToAttrs (
      map
      (unit: {
        name = lib.removeSuffix ".target" unit;
        value = {
          after = ["abird-host-agent-holds.service"];
          requires = ["abird-host-agent-holds.service"];
          unitConfig.ConditionPathExists = conditionsFor resource;
        };
      })
      (systemTargetsFor spec)
    );
  mkUserServiceGates = resource: spec:
    lib.mkMerge (
      map
      (user:
        lib.listToAttrs (
          map
          (unit: {
            name = lib.removeSuffix ".service" unit;
            value.unitConfig.ConditionPathExists = conditionsFor resource;
          })
          (userServicesFor user spec)
        ))
      (userNamesFor spec)
    );
  mkUserTargetGates = resource: spec:
    lib.mkMerge (
      map
      (user:
        lib.listToAttrs (
          map
          (unit: {
            name = lib.removeSuffix ".target" unit;
            value.unitConfig.ConditionPathExists = conditionsFor resource;
          })
          (userTargetsFor user spec)
        ))
      (userNamesFor spec)
    );
  declaredHoldCommands =
    lib.mapAttrsToList
    (resource: declaration: "${configuredPackage}/bin/abird-host-agent _reconcile hold declare --resource ${lib.escapeShellArg resource} --declaration ${lib.escapeShellArg declaration} --defer-enforcement")
    effectiveDeclaredHolds;
  holdReconcileCommands =
    declaredHoldCommands
    ++ [
      "${configuredPackage}/bin/abird-host-agent _reconcile desired-resource-holds --manifest ${lib.escapeShellArg desiredResourceStateManifest}"
      "${configuredPackage}/bin/abird-host-agent _reconcile hold apply"
      "${pkgs.coreutils}/bin/touch ${userHoldReadyMarker}"
    ];
in {
  imports = [./options.nix];

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (name: name != "") typedResourceNames;
        message = "services.abird-host-agent typed resource names must not be empty.";
      }
      {
        assertion = lib.all (id: id != "") (builtins.attrNames cfg.extraResources);
        message = "services.abird-host-agent.extraResources IDs must not be empty.";
      }
      {
        assertion = resourceIdCollisions == [];
        message = "services.abird-host-agent.extraResources must not shadow typed resource IDs: ${lib.concatStringsSep ", " resourceIdCollisions}";
      }
      {
        assertion = !nixbotDeployEnabled || !builtins.hasAttr "controller:nixbot" effectiveResources;
        message = "services.abird-host-agent.nixbotDeploy owns the controller:nixbot resource ID.";
      }
      {
        assertion = lib.all (resource: builtins.hasAttr resource declaredResourcesById) (builtins.attrNames cfg.declaredHolds);
        message = "services.abird-host-agent.declaredHolds keys must refer to declared resources.";
      }
      {
        assertion = lib.all (user: builtins.isInt gatedUserIds.${user}) declaredGatedUsers;
        message = "services.abird-host-agent user-scoped resources require users.users entries with fixed integer UIDs.";
      }
      {
        assertion = declaredProjectedHoldCollisions == [];
        message = "services.abird-host-agent.declaredHolds is a legacy/bootstrap latch and cannot overlap phase-projected holds: ${lib.concatStringsSep ", " declaredProjectedHoldCollisions}";
      }
      {
        assertion = lib.length projectedResourceStateNames == lib.length (lib.unique projectedResourceStateNames);
        message = "services.abird-host-agent.phaseProjections must not declare the same local resource more than once.";
      }
      {
        assertion = lib.length phaseProjectionIds == lib.length (lib.unique phaseProjectionIds);
        message = "services.abird-host-agent phase projections must have unique projection IDs.";
      }
      {
        assertion = lib.intersectLists projectedResourceStateNames (builtins.attrNames cfg.desiredResourceStates) == [];
        message = "services.abird-host-agent desiredResourceStates must not override phaseProjections.";
      }
      {
        assertion = lib.all (resource: builtins.hasAttr resource declaredResourcesById) desiredResourceStateNames;
        message = "services.abird-host-agent.desiredResourceStates keys must refer to declared resources.";
      }
      {
        assertion = lib.all (desired:
          desired.projectionId
          != ""
          && desired.phase != ""
          && builtins.match "[0-9a-f]{64}" desired.intentDigest != null
          && builtins.match "[0-9a-f]{64}" desired.projectionDigest != null
          && (desired.activationRequirementKind == null) == (desired.activationRequirementDigest == null)
          && (desired.activationRequirementKind == null || desired.activationRequirementKind != "")
          && (desired.activationRequirementDigest == null || builtins.match "[0-9a-f]{64}" desired.activationRequirementDigest != null)
          && (desired.holdEpoch != null || desired.activationRequirementDigest == null)
          && (desired.holdEpoch == null) == (desired.transactionId == null)
          && (desired.transactionId == null || desired.transactionId != "")
          && (desired.activationJobId == null || desired.activationJobId != "")
          && ((desired.state == "active" && desired.holdEpoch != null) == (desired.activationJobId != null)))
        (builtins.attrValues effectiveDesiredResourceStates);
        message = "services.abird-host-agent desired resource states require a projection ID and lowercase SHA-256 digests.";
      }
      {
        assertion = lib.all (desired:
          desired.holdEpoch == null || desired.holdEpoch != "")
        (builtins.attrValues effectiveDesiredResourceStates);
        message = "services.abird-host-agent holdEpoch must be null or non-empty and must carry its canonical transaction and activation job identities.";
      }
      {
        assertion = lib.all (desired:
          desired.state == "active" || desired.holdEpoch != null)
        (builtins.attrValues effectiveDesiredResourceStates);
        message = "services.abird-host-agent held and inactive desired resource states require a stable holdEpoch.";
      }
      {
        assertion = lib.all (resource: resource.services != [] || resource.dataPaths != [] || resource.dataRoots != {} || resource.operations != {} || resource.readiness != [] || resource.transfers != {} || resource.fileStates != {} || resource.instances != {} || resource.deployments != {}) declaredResources;
        message = "services.abird-host-agent resources must declare a service, data path, operation, readiness check, or transfer.";
      }
      {
        assertion = lib.all (resource: lib.all (path: lib.hasPrefix "/" path && path != "/") resource.dataPaths) declaredResources;
        message = "services.abird-host-agent resource data paths must be absolute and cannot be root.";
      }
      {
        assertion = lib.all (resource: lib.all (name: validDataRoot name resource.dataRoots.${name}) (builtins.attrNames resource.dataRoots)) declaredResources;
        message = "services.abird-host-agent data roots require safe stable names, absolute non-root paths, and normalized relative excludes.";
      }
      {
        assertion = lib.all (resource: let
          paths = resource.dataPaths ++ map (root: root.path) (builtins.attrValues resource.dataRoots);
        in
          lib.length paths == lib.length (lib.unique paths))
        declaredResources;
        message = "services.abird-host-agent resources cannot declare the same data-root path more than once.";
      }
      {
        assertion = lib.all (resource: lib.all validServiceTarget resource.services) declaredResources;
        message = "services.abird-host-agent resource units must name a non-empty user-manager owner exactly when scope is user.";
      }
      {
        assertion = lib.all (resource: lib.all (state: lib.all validServiceTarget state.reloadServices) (builtins.attrValues resource.fileStates)) declaredResources;
        message = "services.abird-host-agent file-state reload units must name a non-empty user-manager owner exactly when scope is user.";
      }
      {
        assertion = lib.all (path: lib.hasPrefix "/" path && path != "/") cfg.hostDataPaths;
        message = "services.abird-host-agent host data paths must be absolute and cannot be root.";
      }
      {
        assertion = lib.hasPrefix "/" cfg.backupRoot && cfg.backupRoot != "/" && lib.hasPrefix "/" cfg.rsyncProgram && lib.hasPrefix "/" cfg.tarProgram;
        message = "services.abird-host-agent backup and copy paths must be absolute and backupRoot cannot be root.";
      }
      {
        assertion = lib.all (path: lib.hasPrefix "/" path && path != "/") [
          cfg.desiredResourceStateManifestPath
          cfg.desiredResourceStateDirectory
        ];
        message = "services.abird-host-agent desired resource state paths must be absolute and cannot be root.";
      }
      {
        assertion = lib.hasPrefix "/" sshHostEd25519PublicKey && sshHostEd25519PublicKey != "/";
        message = "services.abird-host-agent SSH host public key must be an absolute non-root path.";
      }
      {
        assertion = cfg.brokerTransfer == null || (lib.hasPrefix "/" cfg.brokerTransfer.identityFile && lib.hasPrefix "/" cfg.brokerTransfer.sshProgram && lib.hasPrefix "/" cfg.brokerTransfer.sshAgentProgram && lib.hasPrefix "/" cfg.brokerTransfer.sshAddProgram);
        message = "services.abird-host-agent broker transfer identity and programs must use absolute paths.";
      }
      {
        assertion = !nixbotDeployEnabled || config.services.nixbot.enable;
        message = "services.abird-host-agent.nixbotDeploy requires services.nixbot.enable.";
      }
      {
        assertion = !nixbotDeployEnabled || builtins.hasAttr cfg.nixbotDeploy.repository config.services.nixbot.repos;
        message = "services.abird-host-agent.nixbotDeploy.repository must name a configured Nixbot repository.";
      }
      {
        assertion = !nixbotDeployEnabled || (config.services.nixbot.sshClient.enable && nixbotIdentityFiles != []);
        message = "services.abird-host-agent.nixbotDeploy requires a Nixbot SSH client identity.";
      }
      {
        assertion = !nixbotDeployEnabled || (lib.hasPrefix "/" cfg.nixbotDeploy.hostLocalLockPath && cfg.nixbotDeploy.hostLocalLockPath != "/");
        message = "services.abird-host-agent.nixbotDeploy.hostLocalLockPath must be a concrete absolute path.";
      }
      {
        assertion = lib.all (resource: lib.all (argv: argv != [] && lib.hasPrefix "/" (builtins.head argv)) (builtins.attrValues resource.operations)) declaredResources;
        message = "services.abird-host-agent resource operations require a non-empty argv with an absolute executable.";
      }
      {
        assertion = lib.all (resource: lib.all (check: (check.type != "path" || (check.path != null && lib.hasPrefix "/" check.path)) && (check.type == "path" || check.address != null) && (check.type != "http" || check.host != null)) resource.readiness) declaredResources;
        message = "services.abird-host-agent readiness checks require the fields appropriate to their type.";
      }
      {
        assertion = lib.all (resource: lib.all (transfer: lib.hasPrefix "/" transfer.source && lib.hasPrefix "/" transfer.destination && lib.hasPrefix "/" transfer.rsyncProgram && lib.hasPrefix "/" transfer.tarProgram && (transfer.remoteSource == null || (lib.hasPrefix "/" transfer.remoteSource.sshProgram && lib.hasPrefix "/" transfer.remoteSource.agentProgram && lib.hasPrefix "/" transfer.remoteSource.rsyncProgram && lib.hasPrefix "/" transfer.remoteSource.tarProgram && (transfer.remoteSource.identityFile == null || lib.hasPrefix "/" transfer.remoteSource.identityFile)))) (builtins.attrValues resource.transfers)) declaredResources;
        message = "services.abird-host-agent transfers require absolute local and remote program paths.";
      }
      {
        assertion = lib.all (resource: lib.all (state: lib.hasPrefix "/" state.path) (builtins.attrValues resource.fileStates)) declaredResources;
        message = "services.abird-host-agent file states require absolute paths.";
      }
      {
        assertion = lib.all (resource:
          lib.all (state:
            (state.expectedPreviousSha256 == null || builtins.match "[0-9a-f]{64}" state.expectedPreviousSha256 != null)
            && lib.all (digest: builtins.match "[0-9a-f]{64}" digest != null) state.acceptedPreviousSha256
            && lib.length state.acceptedPreviousSha256 == lib.length (lib.unique state.acceptedPreviousSha256)
            && (state.expectedPreviousSha256 == null || state.acceptedPreviousSha256 == [])
            && (state.validationArgv == [] || lib.hasPrefix "/" (builtins.head state.validationArgv)))
          (builtins.attrValues resource.fileStates))
        declaredResources;
        message = "services.abird-host-agent file states require unique lowercase SHA-256 compare-and-swap digests, one guard form, and an absolute validator executable.";
      }
      {
        assertion = lib.all (resource: lib.all (instance: lib.hasPrefix "/" instance.program) (builtins.attrValues resource.instances)) declaredResources;
        message = "services.abird-host-agent instance programs must be absolute.";
      }
      {
        assertion = lib.all (resource: lib.all (deployment: lib.hasPrefix "/nix/store/" deployment.system) (builtins.attrValues resource.deployments)) declaredResources;
        message = "services.abird-host-agent deployments must reference concrete /nix/store closures.";
      }
    ];

    environment = {
      systemPackages = [configuredPackage];
      etc =
        {
          "abird-host-agent/resources.json".source = resourceManifest;
          "abird-host-agent/desired-resource-states.json".source = desiredResourceStateManifest;
        }
        // lib.mapAttrs' (resource: transaction:
          lib.nameValuePair "abird-host-agent/declared-holds/${holdFileName resource}" {
            text = "${transaction}\n";
            mode = "0444";
          })
        effectiveDeclaredHolds
        // lib.mapAttrs' (resource: desired:
          lib.nameValuePair "abird-host-agent/desired-resource-states/${holdFileName resource}" {
            text = "${builtins.toJSON (desiredStateDocument resource desired)}\n";
            mode = "0444";
          })
        effectiveDesiredResourceStates;
    };

    # switch-to-configuration waits for user generation jobs before restarting
    # changed system units. Reconcile holds and publish the generation marker
    # during activation so the user readiness barrier cannot wait on the later
    # abird-host-agent-holds.service restart.
    system.activationScripts.abird-host-agent-holds = {
      deps = ["etc" "users"];
      supportsDryActivation = false;
      text = ''
        case "''${NIXOS_ACTION-}" in
          switch|test)
            ${pkgs.systemd}/bin/systemd-tmpfiles --create \
              --prefix=${lib.escapeShellArg cfg.stateDirectory} \
              --prefix=/run/abird-host-agent
            ${lib.concatStringsSep "\n" holdReconcileCommands}
            ;;
        esac
      '';
    };

    systemd = {
      tmpfiles.rules =
        [
          "d ${cfg.stateDirectory} 0711 root root -"
          "d ${cfg.stateDirectory}/holds 0711 root root -"
          "d ${cfg.stateDirectory}/declaration-releases 0700 root root -"
          # User managers evaluate activation ConditionPathExists entries. They
          # need search permission on this directory, while root-owned 0600
          # authorization receipts remain unreadable and unlistable.
          "d ${cfg.stateDirectory}/activation-authorizations 0711 root root -"
          "d ${cfg.stateDirectory}/desired-resource-state-receipts 0700 root root -"
          "d ${cfg.stateDirectory}/jobs 0700 root root -"
          "d ${cfg.backupRoot} 0700 root root -"
          "d /run/abird-host-agent 0700 root root -"
          "d /run/abird-host-agent/broker 0700 root root -"
        ]
        ++ lib.optional nixbotDeployEnabled "d ${cfg.nixbotDeploy.hostLocalLockPath} 0755 ${config.services.nixbot.user.name} ${config.services.nixbot.user.group} -";

      services = lib.mkMerge (
        [
          {
            abird-host-agent-holds = {
              description = "Persist and enforce Abird host resource holds";
              wantedBy = ["multi-user.target"];
              wants = gatedUserManagerUnits;
              after = ["local-fs.target" "systemd-tmpfiles-setup.service" "incus.service"] ++ gatedUserManagerUnits;
              before = ["multi-user.target"];
              restartTriggers = [desiredResourceStateManifest];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = holdReconcileCommands;
                ExecStopPost = "${pkgs.coreutils}/bin/rm -f ${userHoldReadyMarker}";
              };
            };

            abird-host-agent-jobs = {
              description = "Resume durable Abird host-agent jobs";
              wantedBy = lib.optional (!nixbotDeployEnabled) "multi-user.target";
              wants = ["network-online.target"];
              after = ["abird-host-agent-desired-resource-states.service" "abird-host-agent-holds.service" "network-online.target"];
              unitConfig.ConditionPathExists = "${cfg.stateDirectory}/jobs-wakeup";
              serviceConfig = {
                Type = "oneshot";
                ExecCondition = lib.optional nixbotDeployEnabled "${lib.getExe' pkgs.util-linux "flock"} -n ${cfg.nixbotDeploy.hostLocalLockPath} ${lib.getExe' pkgs.coreutils "true"}";
                ExecStart = "${configuredPackage}/bin/abird-host-agent _reconcile jobs";
                Restart = "on-failure";
                RestartSec = "5s";
                TimeoutStartSec = "infinity";
              };
            };

            abird-host-agent-desired-resource-states = {
              description = "Converge Abird host desired resource states";
              wantedBy = ["multi-user.target"];
              requires = ["abird-host-agent-holds.service"];
              after = ["abird-host-agent-holds.service"];
              restartTriggers = [desiredResourceStateManifest];
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${configuredPackage}/bin/abird-host-agent _reconcile desired-resource-states --manifest ${lib.escapeShellArg cfg.desiredResourceStateManifestPath}";
                Restart = "on-failure";
                RestartSec = "5s";
                TimeoutStartSec = "infinity";
              };
            };
          }
        ]
        ++ lib.mapAttrsToList mkSystemServiceGates effectiveResources
      );

      targets = lib.mkMerge (lib.mapAttrsToList mkSystemTargetGates effectiveResources);

      paths.abird-host-agent-jobs = {
        description = "Watch for accepted Abird host-agent jobs";
        wantedBy = ["multi-user.target"];
        pathConfig = {
          PathChanged = "${cfg.stateDirectory}/jobs-wakeup";
          Unit = "abird-host-agent-jobs.service";
        };
      };

      paths.abird-host-agent-desired-resource-states = {
        description = "Watch Abird host desired resource states";
        wantedBy = ["multi-user.target"];
        pathConfig = {
          PathChanged = cfg.desiredResourceStateManifestPath;
          Unit = "abird-host-agent-desired-resource-states.service";
        };
      };

      timers.abird-host-agent-jobs = lib.mkIf nixbotDeployEnabled {
        description = "Retry deferred Abird host-agent jobs";
        wantedBy = ["timers.target"];
        timerConfig = {
          OnBootSec = "15s";
          OnUnitInactiveSec = "15s";
          Unit = "abird-host-agent-jobs.service";
        };
      };

      user = {
        services = lib.mkMerge (
          [
            (lib.optionalAttrs (declaredGatedUsers != []) {
              abird-host-agent-holds-ready = {
                description = "Wait for Abird host hold reconciliation";
                restartIfChanged = true;
                restartTriggers = [resourceManifest desiredResourceStateManifest];
                serviceConfig = {
                  Type = "oneshot";
                  ExecStart = waitForUserHoldReady;
                  RemainAfterExit = true;
                };
              };
            })
            userReadinessServiceGates
          ]
          ++ lib.mapAttrsToList mkUserServiceGates effectiveResources
        );
        targets = lib.mkMerge (
          [userReadinessTargetGates]
          ++ lib.mapAttrsToList mkUserTargetGates effectiveResources
        );
      };
    };
  };
}
