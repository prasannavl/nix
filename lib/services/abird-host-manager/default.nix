args @ {
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  cfg = config.services.abird-host-manager;
  phaseProjections = args.phaseProjections or [];
  servicePlacements = args.servicePlacements or {closeouts = {};};
  serviceMoveContract = args.serviceMoveContract or {moves = {};};
  # Projection kinds register exactly one controller adapter. Host-local kinds
  # remain in the registry with no controller command, so adding a projection
  # cannot accidentally route it through a move transaction reconciler.
  projectionAdapters = {
    move.reconcile = projection:
      lib.escapeShellArgs (
        [
          "transaction"
          "_reconcile"
          projection.projection_id
          "--expected-projection-sha256"
          projection.projection_sha256
        ]
        ++ lib.optional
        (builtins.elem projection.projection_id cfg.failedJobSupersessionProjections)
        "--supersede-failed-job"
      );
    resource_hold.reconcile = null;
  };
  projectionAdapter = projection:
    if
      projection ? intent_kind
      && builtins.isString projection.intent_kind
      && builtins.hasAttr projection.intent_kind projectionAdapters
    then builtins.getAttr projection.intent_kind projectionAdapters
    else null;
  controllerProjections = builtins.filter (projection: let
    adapter = projectionAdapter projection;
  in
    adapter
    != null
    && adapter.reconcile != null
    && !(builtins.elem projection.projection_id (servicePlacements.controller_reconcile_exclusions or [])))
  cfg.phaseProjections;
  projectionIds = map (projection: projection.projection_id) cfg.phaseProjections;
  nixbotRepositories =
    if lib.hasAttrByPath ["services" "nixbot" "repos"] options
    then config.services.nixbot.repos
    else {};
  matchingRepositories = lib.filterAttrs (_: repo: repo.path == cfg.repository) nixbotRepositories;
  matchingRepositoryNames = builtins.attrNames matchingRepositories;
  matchingRepositoryName =
    if builtins.length matchingRepositoryNames == 1
    then builtins.head matchingRepositoryNames
    else null;
  matchingRepository =
    if matchingRepositoryName == null
    then null
    else matchingRepositories.${matchingRepositoryName};
  repoReadyUnit =
    if matchingRepository != null && matchingRepository.syncOnBoot
    then "nixbot-repo-${matchingRepositoryName}-ready.service"
    else null;
  publishGitSshCommand =
    if matchingRepository == null
    then null
    else
      lib.escapeShellArgs [
        "${pkgs.openssh}/bin/ssh"
        "-F"
        "/dev/null"
        "-o"
        "GlobalKnownHostsFile=/dev/null"
        "-o"
        "UserKnownHostsFile=${matchingRepository.knownHostsFile}"
        "-o"
        "StrictHostKeyChecking=yes"
        "-o"
        "BatchMode=yes"
        "-o"
        "IdentityFile=none"
        "-o"
        "IdentityAgent=SSH_AUTH_SOCK"
        "-o"
        "IdentitiesOnly=no"
      ];
  managerWrapperArgs =
    lib.optionals (matchingRepository != null) [
      "--set-default"
      "GIT_SSH_COMMAND"
      matchingRepository.gitSshCommand
      "--set-default"
      "ABIRD_HOST_MANAGER_PUBLISH_GIT_SSH_COMMAND"
      publishGitSshCommand
    ]
    ++ lib.optionals (cfg.configOverride != null) [
      "--set-default"
      "ABIRD_HOST_MANAGER_CONFIG_OVERRIDE"
      (toString cfg.configOverride)
    ];
  managerPackage = pkgs.symlinkJoin {
    name = "abird-host-manager-runtime";
    paths = [cfg.package];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = lib.optionalString (managerWrapperArgs != []) ''
      wrapProgram "$out/bin/abird-host-manager" ${lib.escapeShellArgs managerWrapperArgs}
    '';
  };
  reconcileService = projection: let
    adapter = projectionAdapter projection;
    suffix = builtins.substring 0 16 (builtins.hashString "sha256" projection.projection_id);
    manifest = pkgs.writeText "abird-host-manager-projection-${suffix}.json" (builtins.toJSON projection);
  in
    lib.nameValuePair "abird-host-manager-reconcile-${suffix}" {
      description = "Reconcile exact Abird host-manager projection ${projection.projection_id}";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      requires = lib.optional (repoReadyUnit != null) repoReadyUnit;
      after = ["network-online.target" "nixbot.service"] ++ lib.optional (repoReadyUnit != null) repoReadyUnit;
      restartTriggers = [manifest];
      path = [pkgs.gitMinimal pkgs.nix];
      environment =
        {
          ABIRD_HOST_MANAGER_CONTROLLER_EXECUTION = "1";
          HOME = "/var/lib/${cfg.user}";
        }
        // lib.optionalAttrs (cfg.configOverride != null) {
          ABIRD_HOST_MANAGER_CONFIG_OVERRIDE = toString cfg.configOverride;
        };
      script = ''
        set -eu
        ${lib.getExe' managerPackage "abird-host-manager"} \
          --repo-root ${lib.escapeShellArg cfg.repository} \
          --config ${lib.escapeShellArg cfg.configPath} \
          --state-dir ${lib.escapeShellArg cfg.stateDirectory} \
          ${adapter.reconcile projection}
      '';
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.repository;
        RemainAfterExit = true;
      };
    };
  closeoutReconcileService = transactionId: closeout: let
    suffix = builtins.substring 0 16 (builtins.hashString "sha256" transactionId);
    manifest = pkgs.writeText "abird-host-manager-closeout-${suffix}.json" (builtins.toJSON closeout);
  in
    lib.nameValuePair "abird-host-manager-closeout-${suffix}" {
      description = "Finalize deployed Abird host-manager closeout ${transactionId}";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      requires = lib.optional (repoReadyUnit != null) repoReadyUnit;
      after = ["network-online.target" "nixbot.service"] ++ lib.optional (repoReadyUnit != null) repoReadyUnit;
      restartTriggers = [manifest];
      path = [pkgs.gitMinimal pkgs.nix];
      environment = {
        ABIRD_HOST_MANAGER_CONTROLLER_EXECUTION = "1";
        HOME = "/var/lib/${cfg.user}";
      };
      script = ''
        set -eu
        ${lib.getExe' managerPackage "abird-host-manager"} \
          --repo-root ${lib.escapeShellArg cfg.repository} \
          --config ${lib.escapeShellArg cfg.configPath} \
          --state-dir ${lib.escapeShellArg cfg.stateDirectory} \
          transaction _close-reconcile \
          ${lib.escapeShellArg transactionId} \
          --expected-projection-sha256 ${lib.escapeShellArg closeout.projection_sha256}
      '';
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.repository;
        RemainAfterExit = true;
      };
    };
  nixNativeCloseouts = lib.mapAttrs (_: move: {
    inherit (move) affected_hosts;
    # Adoption intentionally retains the inactive-side lease. Cleanup moves
    # the closeout record into stable placement state; only that clean
    # generation may run the digest-bound controller finalizer.
    controller_reconcile = false;
    decision = move.declaration.decision;
    projection_sha256 = move.projection.projection_sha256;
  }) (lib.filterAttrs (_: move: move.declaration.decision != null) serviceMoveContract.moves);
  allCloseouts = (servicePlacements.closeouts or {}) // nixNativeCloseouts;
  controllerCloseouts = lib.filterAttrs (_: closeout: closeout.controller_reconcile or true) allCloseouts;
in {
  options.services.abird-host-manager = {
    enable = lib.mkEnableOption "controller-authoritative Abird host-manager reconciliation";

    package = lib.mkPackageOption pkgs "abird-host-manager" {};

    phaseProjections = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = phaseProjections;
      description = ''
        Validated phase projections injected into this controller generation.
        The reconciler consumes their exact IDs and digests; it never selects or
        infers a desired phase.
      '';
    };

    failedJobSupersessionProjections = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        Projection IDs explicitly authorized by this controller generation to
        preserve a terminal failed host-agent job and retry the same logical
        step under the projection's current immutable policy.
      '';
    };

    repository = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nixbot/nix";
      description = "Authoritative controller repository checkout.";
    };

    configPath = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.repository}/hosts/nixbot.nix";
      description = "Repository-derived host-manager inventory.";
    };

    configOverride = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional controller-local inventory override evaluated on top of
        configPath for both projected reconciliation units and remotely
        dispatched controller commands.
      '';
    };

    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nixbot/abird-host-manager";
      description = "Controller-owned durable workflow journal directory.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "nixbot";
      description = "Controller account owning repository and workflow state.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "nixbot";
      description = "Controller group owning workflow state.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      [
        {
          assertion = builtins.length matchingRepositoryNames <= 1;
          message = "services.abird-host-manager.repository matches more than one services.nixbot.repos path";
        }
        {
          assertion = lib.intersectLists (builtins.attrNames (servicePlacements.closeouts or {})) (builtins.attrNames nixNativeCloseouts) == [];
          message = "legacy and Nix-native host-manager closeouts must not share a transaction ID";
        }
        {
          assertion = builtins.length cfg.failedJobSupersessionProjections == builtins.length (lib.unique cfg.failedJobSupersessionProjections);
          message = "services.abird-host-manager.failedJobSupersessionProjections must be unique";
        }
        {
          assertion = lib.all (projectionId: builtins.elem projectionId projectionIds) cfg.failedJobSupersessionProjections;
          message = "services.abird-host-manager.failedJobSupersessionProjections must name active phase projections";
        }
      ]
      ++ lib.concatMap (projection: [
        {
          assertion = projection ? intent_kind && builtins.isString projection.intent_kind && projection.intent_kind != "";
          message = "services.abird-host-manager phase projection has no non-empty intent_kind";
        }
        {
          assertion = projection ? intent_kind && builtins.isString projection.intent_kind && builtins.hasAttr projection.intent_kind projectionAdapters;
          message = "services.abird-host-manager phase projection has no registered controller adapter";
        }
        {
          assertion = projection ? projection_id && builtins.isString projection.projection_id && projection.projection_id != "";
          message = "services.abird-host-manager phase projection has no non-empty projection_id";
        }
        {
          assertion = projection ? projection_sha256 && builtins.isString projection.projection_sha256 && builtins.match "[0-9a-f]{64}" projection.projection_sha256 != null;
          message = "services.abird-host-manager phase projection has no canonical projection_sha256";
        }
      ])
      cfg.phaseProjections;

    environment.systemPackages = [managerPackage];

    systemd.services = builtins.listToAttrs (
      (map reconcileService controllerProjections)
      ++ (lib.mapAttrsToList closeoutReconcileService controllerCloseouts)
    );
  };
}
