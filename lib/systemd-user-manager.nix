{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.services.systemdUserManager;
  collectionsLib = import ./flake/utils {inherit lib;};

  postActionType = lib.types.submodule ({name, ...}: {
    options = {
      argv = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Command argv to run via a transient systemd --user service.";
      };

      description = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Human-readable description for the transient action.";
      };

      after = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "Other post-action names that must complete before this action runs.";
      };

      execOnFirstRun = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether a brand-new action should run on its first apply pass.";
      };

      observeUnitInactiveAction = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [
          "fail"
          "run-action"
          "start-change-unit"
        ]);
        default = null;
        description = ''
          What to do when a pending action finds `observeUnit` inactive. `fail`
          errors, `run-action` runs the action without requiring the observed
          unit to be active, and `start-change-unit` starts `changeUnit` first.
        '';
      };

      restartTriggers = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [];
        description = "Triggers that mark this action as changed.";
      };

      stampPayload = lib.mkOption {
        type = lib.types.nullOr lib.types.unspecified;
        default = null;
        description = "Optional explicit payload to hash for this action's persisted stamp. Defaults to the action definition fields.";
      };
    };
  });

  unitType = lib.types.submodule ({name, ...}: {
    options = {
      user = lib.mkOption {
        type = lib.types.str;
        description = "User account owning the systemd --user manager.";
      };

      unit = lib.mkOption {
        type = lib.types.str;
        default = "${name}.service";
        description = "User unit name to manage (include suffix).";
      };

      observeUnit = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "User unit whose active state decides whether reconciliation and post-actions should proceed. Defaults to unit.";
      };

      changeUnit = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "User unit to operate on when this managed unit changes. Defaults to unit.";
      };

      onChangeAction = lib.mkOption {
        type = lib.types.enum ["restart" "reload" "start"];
        default = "restart";
        description = "User-manager action to run for previously active changed units.";
      };

      startOnFirstRun = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether a brand-new managed unit should start on its first apply pass.";
      };

      stopOnRemoval = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to stop the managed user unit when this managed-unit entry is removed from config.";
      };

      restartTriggers = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [];
        description = "Triggers that mark this managed unit as changed.";
      };

      stampPayload = lib.mkOption {
        type = lib.types.nullOr lib.types.unspecified;
        default = null;
        description = "Optional explicit payload to hash for this managed unit's persisted stamp. Defaults to the managed-unit definition fields.";
      };

      preActions = lib.mkOption {
        type = lib.types.attrsOf postActionType;
        default = {};
        description = "Ordered pre-reconcile actions for this managed unit.";
      };

      postActions = lib.mkOption {
        type = lib.types.attrsOf postActionType;
        default = {};
        description = "Ordered post-reconcile actions for this managed unit.";
      };
    };
  });

  instances =
    lib.mapAttrsToList
    (name: unit:
      unit
      // {
        unitName = name;
      })
    cfg.instances;

  sanitizeUserKey = user: lib.strings.sanitizeDerivationName user;

  sanitizeStateKey = key: let
    readable = lib.strings.sanitizeDerivationName key;
    digest = builtins.substring 0 8 (builtins.hashString "sha256" key);
  in "${readable}-${digest}";

  sanitizeShellVar = name:
    builtins.replaceStrings ["-" "." "/" "@"] ["_" "_" "_" "_"] name;

  reconcilerServiceNameForUser = user: "systemd-user-manager-reconciler-${sanitizeUserKey user}";
  bootReadyTargetName = "systemd-user-manager-ready.target";

  findSanitizedNameConflicts = entries: let
    renderedToOriginals =
      builtins.foldl'
      (acc: entry:
        acc
        // {
          ${entry.rendered} = (acc.${entry.rendered} or []) ++ [entry.original];
        })
      {}
      entries;
  in
    lib.mapAttrsToList
    (rendered: originals: {
      rendered = rendered;
      originals = lib.unique originals;
    })
    (lib.filterAttrs (_: originals: builtins.length (lib.unique originals) > 1) renderedToOriginals);

  userUidFor = user: let
    users = config.users.users;
  in
    if builtins.hasAttr user users && users.${user}.uid != null
    then users.${user}.uid
    else throw "services.systemdUserManager: user '${user}' is missing or has null uid in users.users";

  mkActionEntry = actionPhase: managedUnit: actionName: action: let
    stampPayload =
      if action.stampPayload != null
      then action.stampPayload
      else {
        kind = "action";
        argv = action.argv;
        description = action.description;
        after = action.after;
        execOnFirstRun = action.execOnFirstRun;
        observeUnitInactiveAction = action.observeUnitInactiveAction;
        restartTriggers = action.restartTriggers;
      };
    stamp = builtins.hashString "sha256" (builtins.toJSON stampPayload);
    stateVar = "action_${sanitizeShellVar actionName}_stamp";
    transientUnit = "systemd-user-manager-action-${sanitizeStateKey "action-${managedUnit.user}-${managedUnit.unitName}-${actionName}"}";
  in {
    name = actionName;
    phase = actionPhase;
    description = action.description;
    argv = action.argv;
    after = action.after;
    execOnFirstRun = action.execOnFirstRun;
    observeUnitInactiveAction = action.observeUnitInactiveAction;
    stamp = stamp;
    stateVar = stateVar;
    transientUnit = transientUnit;
  };

  orderedActionsFor = actionPhase: managedUnit: actions: let
    actionEntries = lib.mapAttrsToList (name: action: mkActionEntry actionPhase managedUnit name action) actions;
    actionNames = map (action: action.name) actionEntries;
    missingDeps =
      lib.concatMap
      (action:
        map
        (dep: "${action.name}->${dep}")
        (builtins.filter (dep: ! builtins.elem dep actionNames) action.after))
      actionEntries;
    topo = lib.toposort (a: b: builtins.elem b.name a.after) actionEntries;
  in
    if missingDeps != []
    then throw "services.systemdUserManager.instances.${managedUnit.unitName}: unknown action dependencies: ${lib.concatStringsSep ", " missingDeps}"
    else if topo ? cycle
    then throw "services.systemdUserManager.instances.${managedUnit.unitName}: action dependency cycle: ${lib.concatStringsSep " -> " (map (action: action.name) topo.cycle)}"
    else topo.result;

  mkUnitEntry = managedUnit: let
    observeUnit =
      if managedUnit.observeUnit != null
      then managedUnit.observeUnit
      else managedUnit.unit;
    changeUnit =
      if managedUnit.changeUnit != null
      then managedUnit.changeUnit
      else managedUnit.unit;
    orderedPreActions = orderedActionsFor "pre-action" managedUnit managedUnit.preActions;
    orderedPostActions = orderedActionsFor "post-action" managedUnit managedUnit.postActions;
    applyFunctionName = "apply_managed_unit_${sanitizeShellVar managedUnit.unitName}";
    stampPayload =
      if managedUnit.stampPayload != null
      then managedUnit.stampPayload
      else {
        kind = "unit";
        unit = managedUnit.unit;
        observeUnit = observeUnit;
        changeUnit = changeUnit;
        onChangeAction = managedUnit.onChangeAction;
        startOnFirstRun = managedUnit.startOnFirstRun;
        stopOnRemoval = managedUnit.stopOnRemoval;
        restartTriggers = managedUnit.restartTriggers;
      };
    stamp = builtins.hashString "sha256" (builtins.toJSON stampPayload);
    stateKey = sanitizeStateKey "unit-${managedUnit.user}-${managedUnit.unitName}";
    writeStateFileBody =
      ''
        cat > "$tmp_state_file" <<'EOF_STATE'
        managed_unit_id='${stateKey}'
        managed_unit_user='${managedUnit.user}'
        managed_unit_name='${managedUnit.unitName}'
        managed_unit_unit='${managedUnit.unit}'
        stop_on_removal='${
          if managedUnit.stopOnRemoval
          then "1"
          else "0"
        }'
        managed_unit_stamp='${stamp}'
      ''
      + lib.concatMapStrings
      (action: ''
        ${action.stateVar}='${action.stamp}'
      '')
      orderedPreActions
      + lib.concatMapStrings
      (action: ''
        ${action.stateVar}='${action.stamp}'
      '')
      orderedPostActions
      + ''
        EOF_STATE
      '';
  in {
    user = managedUnit.user;
    id = stateKey;
    name = managedUnit.unitName;
    unit = managedUnit.unit;
    stamp = stamp;
    preActions = orderedPreActions;
    postActions = orderedPostActions;
    restartTriggers = [stamp] ++ map (action: action.stamp) orderedPreActions ++ map (action: action.stamp) orderedPostActions;
    applyScript = ''
      ${applyFunctionName}() {
        local managed_unit_started_at managed_unit_elapsed unit_file_state
        managed_unit_started_at="$(now_epoch)"
        managed_unit_last_had_work=0
        state_file="$state_dir/${stateKey}.state"
        tmp_state_file="''${state_file}.tmp"
        previous_managed_unit_stamp=""
        if [ -f "$state_file" ]; then
          unset managed_unit_id managed_unit_user managed_unit_name managed_unit_unit stop_on_removal managed_unit_stamp
          ${lib.concatMapStrings (action: "unset ${action.stateVar}\n") orderedPreActions}
          ${lib.concatMapStrings (action: "unset ${action.stateVar}\n") orderedPostActions}
          # shellcheck source=/dev/null
          . "$state_file"
          previous_managed_unit_stamp="''${managed_unit_stamp-}"
        fi

        active_state=""
        run_pending_action() {
          local action_phase action_name action_description transient_unit inactive_action
          action_phase="$1"
          action_name="$2"
          action_description="$3"
          transient_unit="$4"
          inactive_action="$5"
          shift 5

          managed_unit_last_had_work=1
          case "$inactive_action" in
            run-action)
              run_transient_user_command \
                ${lib.escapeShellArg managedUnit.unitName} \
                "$action_phase" \
                "$action_name" \
                "$action_description" \
                "$transient_unit" \
                "$@"
              ;;
            fail|start-change-unit)
              if [ -z "$active_state" ]; then
                if ! active_state="$(unit_stable_state ${lib.escapeShellArg observeUnit})"; then
                  return 1
                fi
              fi
              if [ "$active_state" != active ]; then
                if [ "$inactive_action" = start-change-unit ]; then
                  unit_file_state="$(userctl_unit_file_state ${lib.escapeShellArg changeUnit})"
                  case "$unit_file_state" in
                    disabled|masked|masked-runtime)
                      printf '%s\n' "${managedUnit.unitName}: $action_phase $action_name requires ${changeUnit} to be startable, got unit file state $unit_file_state" >&2
                      return 1
                      ;;
                    *)
                      log_progress "${managedUnit.unitName}: starting ${changeUnit} before $action_phase $action_name"
                      apply_userctl_action ${lib.escapeShellArg managedUnit.unitName} start ${lib.escapeShellArg changeUnit}
                      if [ "''${dry_run-0}" = 1 ]; then
                        active_state="active"
                      elif ! active_state="$(unit_stable_state ${lib.escapeShellArg observeUnit})"; then
                        return 1
                      fi
                      ;;
                  esac
                fi
                if [ "$active_state" != active ]; then
                  printf '%s\n' "${managedUnit.unitName}: $action_phase $action_name requires ${observeUnit} to be active, got $active_state" >&2
                  return 1
                fi
              fi
              run_transient_user_command \
                ${lib.escapeShellArg managedUnit.unitName} \
                "$action_phase" \
                "$action_name" \
                "$action_description" \
                "$transient_unit" \
                "$@"
              active_state=""
              ;;
          esac
        }
        ${lib.concatMapStrings
        (action: ''
          previous_${action.stateVar}="''${${action.stateVar}-}"
          if [ "''${previous_${action.stateVar}}" != '${action.stamp}' ]; then
            if [ -n "''${previous_${action.stateVar}}" ] || [ "${
            if action.execOnFirstRun
            then "1"
            else "0"
          }" = 1 ]; then
              if ! run_pending_action \
                ${lib.escapeShellArg action.phase} \
                ${lib.escapeShellArg action.name} \
                ${lib.escapeShellArg action.description} \
                ${lib.escapeShellArg action.transientUnit} \
                ${lib.escapeShellArg action.observeUnitInactiveAction} \
                ${lib.escapeShellArgs action.argv}; then
                return 1
              fi
            fi
          fi
        '')
        orderedPreActions}

        if [ "$previous_managed_unit_stamp" != '${stamp}' ]; then
          if [ -n "$previous_managed_unit_stamp" ]; then
            managed_unit_last_had_work=1
            log_progress "${managedUnit.unitName}: reconcile action=${managedUnit.onChangeAction}"
            if ! active_state="$(unit_stable_state ${lib.escapeShellArg observeUnit})"; then
              return 1
            fi
            case "$active_state" in
              inactive)
                log_progress "${managedUnit.unitName}: skipped because ${observeUnit} is inactive"
                ;;
              active|failed)
                log_progress "${managedUnit.unitName}: running ${managedUnit.onChangeAction}"
                apply_userctl_action ${lib.escapeShellArg managedUnit.unitName} ${lib.escapeShellArg managedUnit.onChangeAction} ${lib.escapeShellArg changeUnit}
                ;;
              *)
                printf '%s\n' "unexpected stable ActiveState for ${observeUnit}: $active_state" >&2
                return 1
                ;;
            esac
          elif [ "${
        if managedUnit.startOnFirstRun
        then "1"
        else "0"
      }" = 1 ]; then
            managed_unit_last_had_work=1
            log_progress "${managedUnit.unitName}: starting"
            apply_userctl_action ${lib.escapeShellArg managedUnit.unitName} start ${lib.escapeShellArg changeUnit}
            if [ "''${dry_run-0}" = 1 ]; then
              active_state="active"
            fi
          fi
        fi

        if ! active_state="$(unit_stable_state ${lib.escapeShellArg observeUnit})"; then
          return 1
        fi

        if [ "$active_state" = inactive ]; then
          unit_file_state="$(userctl_unit_file_state ${lib.escapeShellArg changeUnit})"
          case "$unit_file_state" in
            disabled|masked|masked-runtime)
              ;;
            *)
              managed_unit_last_had_work=1
              log_progress "${managedUnit.unitName}: starting inactive unit"
              apply_userctl_action ${lib.escapeShellArg managedUnit.unitName} start ${lib.escapeShellArg changeUnit}
              if [ "''${dry_run-0}" = 1 ]; then
                active_state="active"
              elif ! active_state="$(unit_stable_state ${lib.escapeShellArg observeUnit})"; then
                return 1
              fi
              ;;
          esac
        fi

        ${lib.concatMapStrings
        (action: ''
          previous_${action.stateVar}="''${${action.stateVar}-}"
          if [ "''${previous_${action.stateVar}}" != '${action.stamp}' ]; then
            if [ -n "''${previous_${action.stateVar}}" ] || [ "${
            if action.execOnFirstRun
            then "1"
            else "0"
          }" = 1 ]; then
              if ! run_pending_action \
                ${lib.escapeShellArg action.phase} \
                ${lib.escapeShellArg action.name} \
                ${lib.escapeShellArg action.description} \
                ${lib.escapeShellArg action.transientUnit} \
                ${lib.escapeShellArg action.observeUnitInactiveAction} \
                ${lib.escapeShellArgs action.argv}; then
                return 1
              fi
            fi
          fi
        '')
        orderedPostActions}

        if [ "''${dry_run-0}" != 1 ]; then
          ${writeStateFileBody}
          ${pkgs.coreutils}/bin/mv -f "$tmp_state_file" "$state_file"
        fi
        if [ "$managed_unit_last_had_work" -eq 1 ]; then
          managed_unit_elapsed="$(elapsed_since "$managed_unit_started_at")"
          if [ "''${dry_run-0}" = 1 ]; then
            log_progress "${managedUnit.unitName}: dry-activate preview completed elapsed=$managed_unit_elapsed"
          else
            log_progress "${managedUnit.unitName}: completed elapsed=$managed_unit_elapsed"
          fi
        fi
      }
    '';
  };

  managedUnitsByUser =
    builtins.foldl'
    (acc: managedUnit: let
      current = acc.${managedUnit.user} or [];
      unitEntry = mkUnitEntry managedUnit;
    in
      acc
      // {
        ${managedUnit.user} = current ++ [unitEntry];
      })
    {}
    instances;

  sanitizedManagedUnitNameConflicts =
    lib.concatMap
    (user: let
      userInstances = builtins.filter (managedUnit: managedUnit.user == user) instances;
      conflicts = findSanitizedNameConflicts (
        map
        (managedUnit: {
          rendered = sanitizeShellVar managedUnit.unitName;
          original = managedUnit.unitName;
        })
        userInstances
      );
    in
      map
      (conflict: "${user}: ${conflict.rendered} <- ${lib.concatStringsSep ", " conflict.originals}")
      conflicts)
    (builtins.attrNames managedUnitsByUser);

  sanitizedActionNameConflicts =
    lib.concatMap
    (managedUnit: let
      conflicts = findSanitizedNameConflicts (
        (lib.mapAttrsToList
          (actionName: _: {
            rendered = sanitizeShellVar actionName;
            original = "pre:${actionName}";
          })
          managedUnit.preActions)
        ++ (lib.mapAttrsToList
          (actionName: _: {
            rendered = sanitizeShellVar actionName;
            original = "post:${actionName}";
          })
          managedUnit.postActions)
      );
    in
      map
      (conflict: "${managedUnit.user}/${managedUnit.unitName}: ${conflict.rendered} <- ${lib.concatStringsSep ", " conflict.originals}")
      conflicts)
    instances;

  generatedSystemdServiceNames =
    map reconcilerServiceNameForUser (builtins.attrNames managedUnitsByUser);

  duplicateGeneratedSystemdServiceNames =
    collectionsLib.duplicateValues generatedSystemdServiceNames;

  userIdentityStampFor = user: let
    userCfg = config.users.users.${user};
    groupNames = lib.unique ([userCfg.group] ++ userCfg.extraGroups);
    groups =
      lib.genAttrs
      (builtins.filter (group: builtins.hasAttr group config.users.groups) groupNames)
      (group: config.users.groups.${group});
  in
    builtins.hashString "sha256" (builtins.toJSON {
      user = userCfg;
      groups = groups;
    });

  mkMachineUserctlLib = {
    user,
    userUid,
    currentUnitIds,
  }: let
    escapedUser = lib.escapeShellArg user;
    escapedUserUid = lib.escapeShellArg (toString userUid);
  in ''
    now_epoch() {
      ${pkgs.coreutils}/bin/date +%s
    }
    elapsed_since() {
      local start now
      start="$1"
      now="$(now_epoch)"
      printf '%ss' "$((now - start))"
    }
    log_progress() {
      printf '%s\n' "[systemd-user-manager] $*" >&2
    }
    is_transient_userctl_error() {
      printf '%s' "$1" | ${pkgs.gnugrep}/bin/grep -Eq \
        'Transport endpoint is not connected|Failed to connect to bus|Connection refused|No such file or directory'
    }
    managed_user_uid=${escapedUserUid}
    managed_user_name=${escapedUser}
    managed_user_runtime_dir="/run/user/$managed_user_uid"
    managed_user_bus="unix:path=$managed_user_runtime_dir/bus"
    run_as_managed_user() {
      local managed_user_gid
      managed_user_gid="$(${pkgs.coreutils}/bin/id -g "$managed_user_name")"
      ${pkgs.util-linux}/bin/setpriv \
        --reuid="$managed_user_name" \
        --regid="$managed_user_gid" \
        --init-groups \
        ${pkgs.coreutils}/bin/env \
        XDG_RUNTIME_DIR="$managed_user_runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="$managed_user_bus" \
        "$@"
    }
    userctl() {
      local out err rc i stdout_file stderr_file wait_logged
      i=0
      wait_logged=0
      while [ "$i" -lt 60 ]; do
        stdout_file="$(${pkgs.coreutils}/bin/mktemp)"
        stderr_file="$(${pkgs.coreutils}/bin/mktemp)"
        if run_as_managed_user ${pkgs.systemd}/bin/systemctl --user "$@" >"$stdout_file" 2>"$stderr_file"; then
          out="$(${pkgs.coreutils}/bin/cat "$stdout_file")"
          err="$(${pkgs.coreutils}/bin/cat "$stderr_file")"
          ${pkgs.coreutils}/bin/rm -f "$stdout_file" "$stderr_file"
          [ -n "$err" ] && printf '%s\n' "$err" >&2
          [ -n "$out" ] && printf '%s\n' "$out"
          return 0
        fi
        rc=$?
        out="$(${pkgs.coreutils}/bin/cat "$stderr_file")"
        ${pkgs.coreutils}/bin/rm -f "$stdout_file" "$stderr_file"
        if is_transient_userctl_error "$out"; then
          if [ "$wait_logged" -eq 0 ]; then
            log_progress "waiting for transient user-manager command retry: args=$*"
            wait_logged=1
          fi
          i=$((i + 1))
          ${pkgs.coreutils}/bin/sleep 0.5
          continue
        fi
        [ -n "$out" ] && printf '%s\n' "$out" >&2
        return "$rc"
      done
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      return "$rc"
    }
    wait_for_user_manager() {
      local out rc i wait_logged
      i=0
      wait_logged=0
      while [ "$i" -lt 60 ]; do
        out="$(run_as_managed_user ${pkgs.systemd}/bin/systemctl --user list-units --type=service --all --no-legend 2>&1 >/dev/null)" && return 0
        rc=$?
        if is_transient_userctl_error "$out"; then
          if [ "$wait_logged" -eq 0 ]; then
            log_progress "waiting for user manager bus to become reachable"
            wait_logged=1
          fi
          i=$((i + 1))
          ${pkgs.coreutils}/bin/sleep 0.5
          continue
        fi
        [ -n "$out" ] && printf '%s\n' "$out" >&2
        return "$rc"
      done
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      return "$rc"
    }
    stable_state_backoff_seconds() {
      local attempt
      attempt="$1"
      case "$attempt" in
        0) printf '%s\n' "0.5" ;;
        1) printf '%s\n' "1" ;;
        2) printf '%s\n' "2" ;;
        *) printf '%s\n' "5" ;;
      esac
    }
    unit_stable_state() {
      local unit active_state i sleep_seconds
      unit="$1"
      i=0
      while [ "$i" -lt 120 ]; do
        active_state="$(userctl show --property=ActiveState --value "$unit")"
        case "$active_state" in
          activating|deactivating|reloading)
            if [ "$i" -eq 0 ]; then
              log_progress "waiting for stable state: unit=$unit current=$active_state"
            fi
            sleep_seconds="$(stable_state_backoff_seconds "$i")"
            i=$((i + 1))
            ${pkgs.coreutils}/bin/sleep "$sleep_seconds"
            ;;
          *)
            if [ "$i" -gt 0 ]; then
              log_progress "stable state reached: unit=$unit state=$active_state"
            fi
            printf '%s\n' "$active_state"
            return 0
            ;;
        esac
      done
      printf '%s\n' "timed out waiting for stable ActiveState for $unit after progressive backoff" >&2
      return 1
    }
    current_managed_unit_present() {
      case "$1" in
        ${
      if builtins.length currentUnitIds == 0
      then "__no_units__"
      else lib.concatStringsSep "|" currentUnitIds
    }) return 0 ;;
        *) return 1 ;;
      esac
    }
    stop_removed_unit() {
      local unit load_state
      unit="$1"
      if userctl stop "$unit"; then
        return 0
      fi
      load_state="$(userctl_load_state "$unit")" || return 1
      if [ "$load_state" = not-found ]; then
        return 0
      fi
      return 1
    }
    userctl_load_state() {
      local unit out err rc i stdout_file stderr_file wait_logged
      unit="$1"
      i=0
      wait_logged=0
      while [ "$i" -lt 60 ]; do
        stdout_file="$(${pkgs.coreutils}/bin/mktemp)"
        stderr_file="$(${pkgs.coreutils}/bin/mktemp)"
        if run_as_managed_user ${pkgs.systemd}/bin/systemctl --user show --property=LoadState --value "$unit" >"$stdout_file" 2>"$stderr_file"; then
          out="$(${pkgs.coreutils}/bin/cat "$stdout_file")"
          err="$(${pkgs.coreutils}/bin/cat "$stderr_file")"
          ${pkgs.coreutils}/bin/rm -f "$stdout_file" "$stderr_file"
          [ -n "$err" ] && printf '%s\n' "$err" >&2
          printf '%s\n' "$out"
          return 0
        fi
        rc=$?
        out="$(${pkgs.coreutils}/bin/cat "$stderr_file")"
        ${pkgs.coreutils}/bin/rm -f "$stdout_file" "$stderr_file"
        if is_transient_userctl_error "$out"; then
          if [ "$wait_logged" -eq 0 ]; then
            log_progress "waiting for transient load-state query: unit=$unit"
            wait_logged=1
          fi
          i=$((i + 1))
          ${pkgs.coreutils}/bin/sleep 0.5
          continue
        fi
        case "$out" in
          *"not found"*|*"not be found"*|*"not loaded"*)
            printf '%s\n' "not-found"
            return 0
            ;;
        esac
        [ -n "$out" ] && printf '%s\n' "$out" >&2
        return "$rc"
      done
      [ -n "$out" ] && printf '%s\n' "$out" >&2
      return "$rc"
    }
    userctl_unit_file_state() {
      local unit
      unit="$1"
      userctl show --property=UnitFileState --value "$unit"
    }
    cleanup_removed_units() {
      local state_file
      [ -d "$state_dir" ] || return 0
      for state_file in "$state_dir"/*.state; do
        [ -e "$state_file" ] || continue
        unset managed_unit_id managed_unit_user managed_unit_name managed_unit_unit stop_on_removal managed_unit_stamp
        # shellcheck source=/dev/null
        . "$state_file"
        if current_managed_unit_present "''${managed_unit_id-}"; then
          continue
        fi
        log_progress "cleanup: removing stale managed unit user=''${managed_unit_user-unknown} unit=''${managed_unit_unit-unknown}"
        if [ "''${stop_on_removal-0}" = 1 ] && [ -n "''${managed_unit_unit-}" ]; then
          stop_removed_unit "$managed_unit_unit"
        fi
        ${pkgs.coreutils}/bin/rm -f "$state_file"
      done
    }
    run_transient_user_command() {
      local unit_name action_phase action_name description transient_unit action_started_at action_elapsed
      unit_name="$1"
      action_phase="$2"
      action_name="$3"
      description="$4"
      transient_unit="$5"
      shift 5
      if [ "''${dry_run-0}" = 1 ]; then
        log_progress "$unit_name $action_phase $action_name: dry-activate would run"
        return 0
      fi
      action_started_at="$(now_epoch)"
      run_as_managed_user ${pkgs.systemd}/bin/systemd-run \
        --quiet \
        --wait \
        --collect \
        --pipe \
        --service-type=exec \
        --user \
        --unit="$transient_unit" \
        --setenv=PATH=/run/wrappers/bin:/run/current-system/sw/bin \
        --property=KillMode=none \
        --property=Delegate=yes \
        --property=TimeoutStartSec=900 \
        --property=TimeoutStopSec=300 \
        --description="$description" \
        "$@"
      action_elapsed="$(elapsed_since "$action_started_at")"
      log_progress "$unit_name $action_phase $action_name: completed elapsed=$action_elapsed"
    }
    apply_userctl_action() {
      local unit_name verb unit
      unit_name="$1"
      verb="$2"
      unit="$3"
      if [ "''${dry_run-0}" = 1 ]; then
        log_progress "$unit_name: dry-activate would $verb $unit"
        return 0
      fi
      userctl "$verb" "$unit"
    }
  '';

  mkApplyService = user: userUnits: let
    userUid = userUidFor user;
    userAtService = "user@${toString userUid}.service";
    userManagerStatePath = "/run/systemd/users/${toString userUid}";
    serviceName = reconcilerServiceNameForUser user;
    currentUnitIds = map (managedUnit: managedUnit.id) userUnits;
    orderedUnits = lib.sort (a: b: a.name < b.name) userUnits;
    stateDirectoryName = "systemd-user-manager/${sanitizeUserKey user}";
    stateDirectoryPath = "/var/lib/${stateDirectoryName}";
    applyScript = pkgs.writeShellScript "systemd-user-manager-${serviceName}-apply" (
      ''
        set -eu
        dry_run="''${DRY_RUN-0}"
        if [ "$dry_run" = 1 ]; then
          state_dir="''${STATE_DIRECTORY-${stateDirectoryPath}}"
        else
          state_dir="$STATE_DIRECTORY"
          [ -n "$state_dir" ]
        fi
        failed_units=""
        work_units=0
        noop_units=0
        ${mkMachineUserctlLib {
          user = user;
          userUid = userUid;
          currentUnitIds = currentUnitIds;
        }}
        apply_started_at="$(now_epoch)"
        if [ "$dry_run" != 1 ]; then
          ${pkgs.coreutils}/bin/install -d -m 0755 "$state_dir"
        fi
        if ! wait_for_user_manager; then
          if [ "$dry_run" = 1 ]; then
            log_progress "dry-activate: user manager for ${user} is not reachable; skipping preview"
            exit 0
          fi
          exit 1
        fi
        if [ "$dry_run" != 1 ]; then
          userctl daemon-reload
          cleanup_removed_units
        fi
      ''
      + lib.concatStringsSep "\n" (map (managedUnit: managedUnit.applyScript) orderedUnits)
      + "\n"
      + lib.concatStringsSep "\n" (map (managedUnit: ''
          if ! ${"apply_managed_unit_${sanitizeShellVar managedUnit.name}"}; then
            log_progress "${managedUnit.name}: failed"
            failed_units="''${failed_units}${
            if managedUnit.name != ""
            then " ${managedUnit.name}"
            else ""
          }"
          elif [ "$managed_unit_last_had_work" -eq 1 ]; then
            work_units=$((work_units + 1))
          else
            noop_units=$((noop_units + 1))
          fi
        '')
        orderedUnits)
      + ''

        if [ -n "$failed_units" ]; then
          if [ "$dry_run" = 1 ]; then
            log_progress "dry-activate preview failed: user=${user} failed_units=''${failed_units} elapsed=$(elapsed_since "$apply_started_at")"
          else
            log_progress "apply failed: user=${user} failed_units=''${failed_units} elapsed=$(elapsed_since "$apply_started_at")"
          fi
          printf '%s\n' "failed managed units:''${failed_units}" >&2
          exit 1
        fi
        if [ "$dry_run" != 1 ]; then
          userctl start ${lib.escapeShellArg bootReadyTargetName}
        else
          log_progress "dry-activate: would start ${bootReadyTargetName}"
        fi
        if [ "$work_units" -gt 0 ] || [ "$dry_run" = 1 ]; then
          if [ "$dry_run" = 1 ]; then
            log_progress "dry-activate preview: user=${user} elapsed=$(elapsed_since "$apply_started_at") would_change_or_restart=$work_units noops=$noop_units"
          else
          log_progress "apply completed: user=${user} elapsed=$(elapsed_since "$apply_started_at") changed_or_restarted=$work_units noops=$noop_units"
          fi
        fi
      ''
    );
    restartTriggers = lib.concatMap (managedUnit: managedUnit.restartTriggers) orderedUnits;
  in {
    inherit applyScript serviceName stateDirectoryPath;
    name = serviceName;
    value = {
      description = "Reconcile serialized systemd --user state for ${user}";
      after = [
        "multi-user.target"
        userAtService
      ];
      wantedBy = ["multi-user.target"];
      wants = [userAtService];
      inherit restartTriggers;
      restartIfChanged = true;
      stopIfChanged = true;
      unitConfig.ConditionPathExists = userManagerStatePath;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        StateDirectory = stateDirectoryName;
        # A single reconcile pass can synchronously start multiple user units.
        # Cold boot on hosts like pvl-x2 can legitimately take well past the
        # default systemd 90s start timeout.
        TimeoutStartSec = 900;
        ExecStart = "${applyScript}";
      };
    };
  };

  applyServicesByUser = lib.mapAttrs mkApplyService managedUnitsByUser;
in {
  options.services.systemdUserManager = {
    instances = lib.mkOption {
      type = lib.types.attrsOf unitType;
      default = {};
      description = ''
        Managed systemd --user units reconciled through one serialized
        system-managed apply service per user.
      '';
    };
  };

  config = {
    system.activationScripts.systemdUserManagerReconcilerRun = lib.stringAfter ["etc"] (
      let
        reconcilerUsers = builtins.attrNames applyServicesByUser;
      in
        ''
          set -eu
          systemd_user_manager_reconciler_run() {
            wait_for_reconciler() {
              local unit previous_invocation current_invocation active_state sub_state result i log_pid
              unit="$1"
              reconciler_invocation_id=""
            failed_units=""
            work_units=0
            noop_units=0
            previous_invocation="$(${pkgs.systemd}/bin/systemctl show "$unit" --property=InvocationID --value 2>/dev/null || true)"
            active_state="$(${pkgs.systemd}/bin/systemctl show "$unit" --property=ActiveState --value 2>/dev/null || true)"
            sub_state="$(${pkgs.systemd}/bin/systemctl show "$unit" --property=SubState --value 2>/dev/null || true)"
            if [ "$active_state" = active ] && [ "$sub_state" = exited ]; then
              ${pkgs.systemd}/bin/systemctl restart --no-block "$unit"
            else
              ${pkgs.systemd}/bin/systemctl start --no-block "$unit"
            fi
            i=0
            while [ "$i" -lt 1800 ]; do
              current_invocation="$(${pkgs.systemd}/bin/systemctl show "$unit" --property=InvocationID --value 2>/dev/null || true)"
              if [ -n "$current_invocation" ] && [ "$current_invocation" != "$previous_invocation" ]; then
                reconciler_invocation_id="$current_invocation"
                break
              fi
              ${pkgs.coreutils}/bin/sleep 0.5
              i=$((i + 1))
            done
            if [ -z "$reconciler_invocation_id" ]; then
              printf '%s\n' "[systemd-user-manager] timed out waiting for new invocation for $unit" >&2
              return 1
            fi

            ${pkgs.systemd}/bin/journalctl _SYSTEMD_INVOCATION_ID="$reconciler_invocation_id" --no-pager -o cat --follow \
              | ${pkgs.gnugrep}/bin/grep --line-buffered -vE '^(Starting |Started |Finished |Stopped |systemd-user-manager-reconciler-.*: Deactivated successfully\\.)' &
            log_pid=$!

            i=0
            while [ "$i" -lt 1800 ]; do
              active_state="$(${pkgs.systemd}/bin/systemctl show "$unit" --property=ActiveState --value 2>/dev/null || true)"
              sub_state="$(${pkgs.systemd}/bin/systemctl show "$unit" --property=SubState --value 2>/dev/null || true)"
              result="$(${pkgs.systemd}/bin/systemctl show "$unit" --property=Result --value 2>/dev/null || true)"
              case "$active_state:$sub_state:$result" in
                active:exited:success|inactive:dead:success)
                  ${pkgs.coreutils}/bin/kill "$log_pid" 2>/dev/null || true
                  return 0
                  ;;
                failed:failed:*|inactive:dead:failed)
                  ${pkgs.coreutils}/bin/kill "$log_pid" 2>/dev/null || true
                  return 1
                  ;;
              esac
              ${pkgs.coreutils}/bin/sleep 0.5
              i=$((i + 1))
            done
            ${pkgs.coreutils}/bin/kill "$log_pid" 2>/dev/null || true
            printf '%s\n' "[systemd-user-manager] timed out waiting for $unit" >&2
            return 1
            }
            case "''${NIXOS_ACTION-}" in
              switch|test)
                printf '%s\n' "[systemd-user-manager] activation hook start"
                ${pkgs.systemd}/bin/systemctl daemon-reload
        ''
        + lib.concatStringsSep "\n"
        (map
          (user: let
            serviceName = applyServicesByUser.${user}.serviceName;
          in ''
            if ${pkgs.systemd}/bin/systemctl list-unit-files --type=service --no-legend | ${pkgs.gnugrep}/bin/grep -Fq "${serviceName}.service"; then
              printf '%s\n' "[systemd-user-manager] starting ${serviceName}.service"
              if ! wait_for_reconciler ${serviceName}.service; then
                invocation_id="$reconciler_invocation_id"
                if [ -n "$invocation_id" ]; then
                  ${pkgs.systemd}/bin/journalctl _SYSTEMD_INVOCATION_ID="$invocation_id" --no-pager -o cat \
                    | ${pkgs.gnugrep}/bin/grep -vE '^(Starting |Started |Finished |Stopped |systemd-user-manager-reconciler-.*: Deactivated successfully\\.)' || true
                fi
                printf '%s\n' "[systemd-user-manager] ${serviceName}.service failed"
                return 1
              fi
              printf '%s\n' "[systemd-user-manager] finished ${serviceName}.service"
            fi
          '')
          reconcilerUsers)
        + ''
            printf '%s\n' "[systemd-user-manager] activation hook complete"
            ;;
          dry-activate)
            printf '%s\n' "[systemd-user-manager] dry-activate preview start"
        ''
        + lib.concatStringsSep "\n"
        (map
          (user: let
            artifacts = applyServicesByUser.${user};
          in ''
            printf '%s\n' "[systemd-user-manager] dry-activate preview ${artifacts.serviceName}.service"
            STATE_DIRECTORY=${lib.escapeShellArg artifacts.stateDirectoryPath} DRY_RUN=1 ${artifacts.applyScript}
          '')
          reconcilerUsers)
        + ''
                printf '%s\n' "[systemd-user-manager] dry-activate preview complete"
                ;;
              *)
                printf '%s\n' "[systemd-user-manager] activation hook skipped for action=''${NIXOS_ACTION-unknown}"
                ;;
            esac
          }
          systemd_user_manager_reconciler_run
        ''
    );

    system.activationScripts.systemdUserManagerPrune = lib.stringAfter ["users"] (
      let
        managedUsers = builtins.attrNames managedUnitsByUser;
        escapedManagedUsers =
          if managedUsers == []
          then "__no_managed_users__"
          else lib.concatStringsSep "|" (map sanitizeUserKey managedUsers);
      in ''
        set -eu
        systemd_user_manager_prune() {
          stop_removed_user_unit() {
            local managed_unit_user managed_unit_unit managed_user_uid managed_user_gid managed_user_runtime_dir managed_user_bus
            managed_unit_user="$1"
            managed_unit_unit="$2"
            managed_user_uid="$(${pkgs.coreutils}/bin/id -u "$managed_unit_user" 2>/dev/null || true)"
            [ -n "$managed_user_uid" ] || return 0
            if ! ${pkgs.systemd}/bin/systemctl is-active --quiet "user@''${managed_user_uid}.service"; then
              return 0
            fi
            managed_user_gid="$(${pkgs.coreutils}/bin/id -g "$managed_unit_user" 2>/dev/null || true)"
            [ -n "$managed_user_gid" ] || return 1
            managed_user_runtime_dir="/run/user/$managed_user_uid"
            managed_user_bus="unix:path=$managed_user_runtime_dir/bus"
            ${pkgs.util-linux}/bin/setpriv \
              --reuid="$managed_unit_user" \
              --regid="$managed_user_gid" \
              --init-groups \
              ${pkgs.coreutils}/bin/env \
              XDG_RUNTIME_DIR="$managed_user_runtime_dir" \
              DBUS_SESSION_BUS_ADDRESS="$managed_user_bus" \
              ${pkgs.systemd}/bin/systemctl --user stop "$managed_unit_unit" >/dev/null 2>&1
          }
          case "''${NIXOS_ACTION-}" in
            switch|test)
              state_root="/var/lib/systemd-user-manager"
              stop_failed=0
              if [ -d "$state_root" ]; then
                for user_state_dir in "$state_root"/*; do
                  [ -d "$user_state_dir" ] || continue
                  user_state_key="$(basename "$user_state_dir")"
                  case "$user_state_key" in
                    ${escapedManagedUsers}) continue ;;
                  esac
                  for state_file in "$user_state_dir"/*.state; do
                    [ -e "$state_file" ] || continue
                    unset managed_unit_user managed_unit_unit stop_on_removal
                    # shellcheck source=/dev/null
                    . "$state_file"
                    if [ "''${stop_on_removal-0}" = 1 ] && [ -n "''${managed_unit_unit-}" ] && [ -n "''${managed_unit_user-}" ]; then
                      if ! stop_removed_user_unit "$managed_unit_user" "$managed_unit_unit"; then
                        printf '%s\n' "systemd-user-manager prune: failed to stop removed user unit $managed_unit_unit for $managed_unit_user" >&2
                        stop_failed=1
                        continue
                      fi
                    fi
                    ${pkgs.coreutils}/bin/rm -f "$state_file"
                  done
                  ${pkgs.coreutils}/bin/rmdir "$user_state_dir" 2>/dev/null || true
                done
              fi
              if [ "$stop_failed" -ne 0 ]; then
                return 1
              fi
              ;;
            dry-activate)
              printf '%s\n' "[systemd-user-manager] dry-activate preview prune skipped"
              ;;
            *)
              printf '%s\n' "[systemd-user-manager] prune activation skipped for action=''${NIXOS_ACTION-unknown}"
              ;;
          esac
        }
        systemd_user_manager_prune
      ''
    );

    system.activationScripts.systemdUserManagerIdentity = lib.stringAfter ["users"] (
      let
        stateDir = "/run/nixos/systemd-user-manager";
        usersWithManagedEntries = builtins.attrNames managedUnitsByUser;
      in
        ''
          set -eu
          systemd_user_manager_identity() {
            case "''${NIXOS_ACTION-}" in
              switch|test)
                ${pkgs.coreutils}/bin/install -d -m 0755 ${stateDir}
        ''
        + lib.concatStringsSep "\n"
        (map
          (user: let
            uid = toString (userUidFor user);
            stamp = userIdentityStampFor user;
            stampFile = "${stateDir}/identity-${sanitizeUserKey user}.stamp";
          in ''
            current_stamp="$(${pkgs.coreutils}/bin/cat ${lib.escapeShellArg stampFile} 2>/dev/null || true)"
            if [ "$current_stamp" != "${stamp}" ]; then
              if ${pkgs.systemd}/bin/systemctl is-active --quiet user@${uid}.service; then
                ${pkgs.systemd}/bin/systemctl restart user@${uid}.service
              fi
              ${pkgs.coreutils}/bin/printf '%s\n' "${stamp}" > ${lib.escapeShellArg stampFile}
            fi
          '')
          usersWithManagedEntries)
        + ''
                ;;
              dry-activate)
                printf '%s\n' "[systemd-user-manager] dry-activate preview identity refresh skipped"
                ;;
              *)
                printf '%s\n' "[systemd-user-manager] identity activation skipped for action=''${NIXOS_ACTION-unknown}"
                ;;
            esac
          }
          systemd_user_manager_identity
        ''
    );

    assertions =
      [
        {
          assertion = duplicateGeneratedSystemdServiceNames == [];
          message = "services.systemdUserManager: duplicate generated systemd service names: ${lib.concatStringsSep ", " duplicateGeneratedSystemdServiceNames}";
        }
        {
          assertion = sanitizedManagedUnitNameConflicts == [];
          message = "services.systemdUserManager: managed unit names collide after shell-name sanitization: ${lib.concatStringsSep "; " sanitizedManagedUnitNameConflicts}";
        }
        {
          assertion = sanitizedActionNameConflicts == [];
          message = "services.systemdUserManager: action names collide after shell-name sanitization: ${lib.concatStringsSep "; " sanitizedActionNameConflicts}";
        }
      ]
      ++ lib.concatMap
      (managedUnit: [
        {
          assertion = builtins.hasAttr managedUnit.user config.users.users;
          message = "services.systemdUserManager: users.users.${managedUnit.user} is not defined";
        }
        {
          assertion = (! builtins.hasAttr managedUnit.user config.users.users) || (config.users.users.${managedUnit.user}.uid != null);
          message = "services.systemdUserManager: users.users.${managedUnit.user}.uid must be set";
        }
      ])
      instances;

    systemd.services = lib.listToAttrs (
      map
      (artifacts: {
        name = artifacts.name;
        value = artifacts.value;
      })
      (builtins.attrValues applyServicesByUser)
    );
    systemd.user.targets.${lib.removeSuffix ".target" bootReadyTargetName} = {
      description = "Managed user units ready target";
    };
  };
}
