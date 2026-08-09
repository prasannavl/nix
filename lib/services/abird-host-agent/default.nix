{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.abird-host-agent;
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
  declaredGatedUsers = lib.unique (lib.concatMap (resource: builtins.attrNames resource.gatedUserUnits) declaredResources);
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
  declaredHoldMarker = resource: "${cfg.declaredHoldDirectory}/${holdFileName resource}";
  declarationRelease = resource: declaration: "${cfg.stateDirectory}/declaration-releases/${builtins.hashString "sha256" resource}/${builtins.hashString "sha256" declaration}.json";
  configuredPackage = pkgs.symlinkJoin {
    name = "abird-host-agent-configured";
    paths = [cfg.package];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = ''
      wrapProgram "$out/bin/abird-host-agent" \
        --set ABIRD_HOST_AGENT_STATE_DIR ${lib.escapeShellArg cfg.stateDirectory} \
        --set ABIRD_HOST_AGENT_RESOURCE_MANIFEST ${lib.escapeShellArg cfg.manifestPath} \
        --set ABIRD_HOST_AGENT_SYSTEMCTL ${lib.escapeShellArg "${pkgs.systemd}/bin/systemctl"} \
        --set ABIRD_HOST_AGENT_JOURNALCTL ${lib.escapeShellArg "${pkgs.systemd}/bin/journalctl"} \
        --set ABIRD_HOST_AGENT_RUNUSER ${lib.escapeShellArg "${pkgs.shadow}/bin/runuser"} \
        --set ABIRD_HOST_AGENT_PODMAN ${lib.escapeShellArg "${pkgs.podman}/bin/podman"} \
        --set ABIRD_HOST_AGENT_NIX_COLLECT_GARBAGE ${lib.escapeShellArg "${pkgs.nix}/bin/nix-collect-garbage"}
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
        runuser_program = "${pkgs.shadow}/bin/runuser";
        env_program = "${pkgs.coreutils}/bin/env";
        user = config.services.nixbot.user.name;
        home = config.services.nixbot.stateDir;
        repository_url = nixbotRepository.url;
        repository_path = nixbotRepository.path;
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
  conditionsFor = resource:
    ["!${holdFile resource}"]
    ++ lib.optionals (builtins.hasAttr resource cfg.declaredHolds) [
      "|!${declaredHoldMarker resource}"
      "|${declarationRelease resource cfg.declaredHolds.${resource}}"
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
    (resource: declaration: "${configuredPackage}/bin/abird-host-agent _reconcile hold declare --resource ${lib.escapeShellArg resource} --declaration ${lib.escapeShellArg declaration}")
    cfg.declaredHolds;
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
        }
        // lib.mapAttrs' (resource: transaction:
          lib.nameValuePair "abird-host-agent/declared-holds/${holdFileName resource}" {
            text = "${transaction}\n";
            mode = "0444";
          })
        cfg.declaredHolds;
    };

    systemd = {
      tmpfiles.rules = [
        "d ${cfg.stateDirectory} 0711 root root -"
        "d ${cfg.stateDirectory}/holds 0711 root root -"
        "d ${cfg.stateDirectory}/declaration-releases 0700 root root -"
        "d ${cfg.stateDirectory}/jobs 0700 root root -"
        "d ${cfg.backupRoot} 0700 root root -"
        "d /run/abird-host-agent 0700 root root -"
        "d /run/abird-host-agent/broker 0700 root root -"
      ];

      services = lib.mkMerge (
        [
          {
            abird-host-agent-holds = {
              description = "Persist and enforce Abird host resource holds";
              wantedBy = ["multi-user.target"];
              after = ["local-fs.target" "systemd-tmpfiles-setup.service" "incus.service"];
              before = ["multi-user.target"];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                ExecStart = declaredHoldCommands ++ ["${configuredPackage}/bin/abird-host-agent _reconcile hold apply"];
              };
            };

            abird-host-agent-jobs = {
              description = "Resume durable Abird host-agent jobs";
              wantedBy = ["multi-user.target"];
              wants = ["network-online.target"];
              after = ["abird-host-agent-holds.service" "network-online.target"];
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${configuredPackage}/bin/abird-host-agent _reconcile jobs";
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
          PathChanged = "${cfg.stateDirectory}/jobs";
          Unit = "abird-host-agent-jobs.service";
        };
      };

      user = {
        services = lib.mkMerge (lib.mapAttrsToList mkUserServiceGates effectiveResources);
        targets = lib.mkMerge (lib.mapAttrsToList mkUserTargetGates effectiveResources);
      };
    };
  };
}
