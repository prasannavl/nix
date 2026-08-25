{
  config,
  lib,
  options,
  pkgs,
  phaseProjections ? [],
  ...
}: let
  cfg = config.services.abird-host-manager;
  # Projection kinds register exactly one controller adapter. Host-local kinds
  # remain in the registry with no controller command, so adding a projection
  # cannot accidentally route it through a move transaction reconciler.
  projectionAdapters = {
    move.reconcile = projection: ''
      transaction reconcile ${lib.escapeShellArg projection.projection_id} \
        --expected-projection-sha256 ${lib.escapeShellArg projection.projection_sha256} \
        --execute
    '';
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
    adapter != null && adapter.reconcile != null)
  cfg.phaseProjections;
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
  managerPackage = pkgs.symlinkJoin {
    name = "abird-host-manager-runtime";
    paths = [cfg.package];
    nativeBuildInputs = [pkgs.makeWrapper];
    postBuild = lib.optionalString (matchingRepository != null) ''
      wrapProgram "$out/bin/abird-host-manager" \
        --set-default GIT_SSH_COMMAND ${lib.escapeShellArg matchingRepository.gitSshCommand} \
        --set-default ABIRD_HOST_MANAGER_PUBLISH_GIT_SSH_COMMAND ${lib.escapeShellArg publishGitSshCommand}
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

    systemd.services = builtins.listToAttrs (map reconcileService controllerProjections);
  };
}
