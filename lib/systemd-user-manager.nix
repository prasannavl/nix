{
  lib,
  pkgs,
  config,
  ...
}: let
  cfg = config.services.systemdUserManager;
  collectionsLib = import ./flake/utils {inherit lib;};

  unitType = lib.types.submodule ({name, ...}: {
    options = {
      user = lib.mkOption {
        type = lib.types.str;
        description = "User account owning the systemd --user manager.";
      };

      unit = lib.mkOption {
        type = lib.types.str;
        default = "${name}.service";
        description = "User unit name to keep started by the per-user reconciler.";
      };

      stopOnRemoval = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether removing the managed entry should stop the old user unit during dispatcher stop.";
      };

      restartTriggers = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [];
        description = "Triggers that mark this managed unit as changed.";
      };

      stampPayload = lib.mkOption {
        type = lib.types.nullOr lib.types.unspecified;
        default = null;
        description = "Optional explicit payload to hash for this managed unit stamp. Defaults to the managed-unit definition fields.";
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

  dispatcherServiceNameForUser = user: "systemd-user-manager-dispatcher-${sanitizeUserKey user}";

  reconcilerServiceNameForUser = user: "systemd-user-manager-reconciler-${sanitizeUserKey user}";

  bootReadyTargetName = "systemd-user-manager-ready.target";
  managedUserActionPath = "/run/wrappers/bin:/run/current-system/sw/bin";

  userUidFor = user: let
    users = config.users.users;
  in
    if builtins.hasAttr user users && users.${user}.uid != null
    then users.${user}.uid
    else throw "services.systemdUserManager: user '${user}' is missing or has null uid in users.users";

  mkUnitEntry = managedUnit: let
    stampPayload =
      if managedUnit.stampPayload != null
      then managedUnit.stampPayload
      else {
        kind = "unit";
        unit = managedUnit.unit;
        stopOnRemoval = managedUnit.stopOnRemoval;
        restartTriggers = managedUnit.restartTriggers;
      };
    stamp = builtins.hashString "sha256" (builtins.toJSON stampPayload);
  in {
    user = managedUnit.user;
    name = managedUnit.unitName;
    unit = managedUnit.unit;
    stopOnRemoval = managedUnit.stopOnRemoval;
    stamp = stamp;
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

  generatedDispatcherServiceNames =
    map dispatcherServiceNameForUser (builtins.attrNames managedUnitsByUser);

  generatedReconcilerServiceNames =
    map reconcilerServiceNameForUser (builtins.attrNames managedUnitsByUser);

  duplicateGeneratedSystemdServiceNames =
    collectionsLib.duplicateValues (generatedDispatcherServiceNames ++ generatedReconcilerServiceNames);

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

  userMetadataByUser =
    lib.mapAttrs
    (user: userUnits: let
      sortedUnits = lib.sort (a: b: a.name < b.name) userUnits;
      metadata = {
        version = 1;
        user = user;
        identityStamp = userIdentityStampFor user;
        managedUnits =
          map
          (managedUnit: {
            name = managedUnit.name;
            unit = managedUnit.unit;
            stopOnRemoval = managedUnit.stopOnRemoval;
            stamp = managedUnit.stamp;
          })
          sortedUnits;
      };
      rendered = builtins.toJSON metadata;
    in {
      json = metadata;
      hash = builtins.hashString "sha256" rendered;
      file = pkgs.writeText "systemd-user-manager-${sanitizeUserKey user}.json" rendered;
    })
    managedUnitsByUser;

  mkRootUserctlLib = {
    user,
    userUid,
  }: let
    escapedUser = lib.escapeShellArg user;
    escapedUserUid = lib.escapeShellArg (toString userUid);
  in ''
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
  '';

  mkUserctlLib = ''
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
    userctl() {
      local out err rc i stdout_file stderr_file wait_logged
      i=0
      wait_logged=0
      while [ "$i" -lt 60 ]; do
        stdout_file="$(${pkgs.coreutils}/bin/mktemp)"
        stderr_file="$(${pkgs.coreutils}/bin/mktemp)"
        if ${pkgs.systemd}/bin/systemctl --user "$@" >"$stdout_file" 2>"$stderr_file"; then
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
        out="$(${pkgs.systemd}/bin/systemctl --user list-units --type=service --all --no-legend 2>&1 >/dev/null)" && return 0
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
      local elapsed_seconds
      elapsed_seconds="$1"
      case "$elapsed_seconds" in
        0|1) printf '%s\n' "0.5" ;;
        2|3) printf '%s\n' "1" ;;
        4|5|6|7) printf '%s\n' "2" ;;
        *) printf '%s\n' "5" ;;
      esac
    }
    unit_stable_state() {
      local unit active_state sub_state result started_at now elapsed_seconds sleep_seconds
      unit="$1"
      started_at="$(now_epoch)"
      while true; do
        active_state="$(userctl show --property=ActiveState --value "$unit")"
        sub_state="$(userctl show --property=SubState --value "$unit")"
        result="$(userctl show --property=Result --value "$unit")"
        case "$active_state" in
          activating|deactivating|reloading)
            now="$(now_epoch)"
            elapsed_seconds="$((now - started_at))"
            if [ "$sub_state" = auto-restart ] || [ "$result" = failed ]; then
              printf '%s\n' "unit $unit entered transitional failure state active=$active_state sub=$sub_state result=$result" >&2
              return 1
            fi
            if [ "$elapsed_seconds" -eq 0 ]; then
              log_progress "waiting for stable state: unit=$unit current=$active_state sub=$sub_state"
            fi
            if [ "$elapsed_seconds" -ge 30 ]; then
              printf '%s\n' "timed out waiting 30s for stable ActiveState for $unit (active=$active_state sub=$sub_state result=$result)" >&2
              return 1
            fi
            sleep_seconds="$(stable_state_backoff_seconds "$elapsed_seconds")"
            ${pkgs.coreutils}/bin/sleep "$sleep_seconds"
            ;;
          *)
            now="$(now_epoch)"
            elapsed_seconds="$((now - started_at))"
            if [ "$elapsed_seconds" -gt 0 ]; then
              log_progress "stable state reached: unit=$unit state=$active_state sub=$sub_state"
            fi
            printf '%s\n' "$active_state"
            return 0
            ;;
        esac
      done
    }
    userctl_unit_file_state() {
      local unit
      unit="$1"
      userctl show --property=UnitFileState --value "$unit"
    }
    start_managed_unit() {
      local managed_name managed_unit active_state unit_file_state
      managed_name="$1"
      managed_unit="$2"
      managed_unit_had_work=0

      if ! active_state="$(unit_stable_state "$managed_unit")"; then
        return 1
      fi

      case "$active_state" in
        active)
          return 0
          ;;
        inactive|failed)
          unit_file_state="$(userctl_unit_file_state "$managed_unit")"
          case "$unit_file_state" in
            disabled|masked|masked-runtime)
              log_progress "$managed_name: skipped because $managed_unit is $unit_file_state"
              return 0
              ;;
          esac
          managed_unit_had_work=1
          if [ "''${dry_run-0}" = 1 ]; then
            log_progress "$managed_name: dry-activate would start $managed_unit"
          else
            log_progress "$managed_name: starting $managed_unit"
            userctl --no-block start "$managed_unit"
          fi
          return 0
          ;;
        *)
          printf '%s\n' "unexpected stable ActiveState for $managed_unit: $active_state" >&2
          return 1
          ;;
      esac
    }
  '';

  mkUserReconciler = user: userUnits: let
    metadata = userMetadataByUser.${user};
    serviceName = reconcilerServiceNameForUser user;
    applyScript = pkgs.writeShellScript "systemd-user-manager-${serviceName}-apply" ''
      set -eu
      dry_run="''${DRY_RUN-0}"
      metadata_file="''${SYSTEMD_USER_MANAGER_METADATA-${metadata.file}}"
      failed_units=""
      work_units=0
      noop_units=0
      ${mkUserctlLib}
      apply_started_at="$(now_epoch)"

      if ! wait_for_user_manager; then
        if [ "$dry_run" = 1 ]; then
          log_progress "dry-activate: user manager for ${user} is not reachable; skipping preview"
          exit 0
        fi
        exit 1
      fi

      if [ "$dry_run" != 1 ]; then
        userctl daemon-reload
      fi

      while IFS=$'\t' read -r managed_name managed_unit; do
        if ! start_managed_unit "$managed_name" "$managed_unit"; then
          log_progress "$managed_name: failed"
          failed_units="''${failed_units} $managed_name"
        elif [ "$managed_unit_had_work" -eq 1 ]; then
          work_units=$((work_units + 1))
        else
          noop_units=$((noop_units + 1))
        fi
      done < <(
        ${pkgs.jq}/bin/jq -r '.managedUnits | sort_by(.name)[] | [.name, .unit] | @tsv' "$metadata_file"
      )

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
          log_progress "dry-activate preview: user=${user} elapsed=$(elapsed_since "$apply_started_at") would_start=$work_units noops=$noop_units"
        else
          log_progress "apply completed: user=${user} elapsed=$(elapsed_since "$apply_started_at") started=$work_units noops=$noop_units"
        fi
      fi
    '';
  in {
    applyScript = applyScript;
    metadataFile = metadata.file;
    metadataHash = metadata.hash;
    serviceName = serviceName;
    user = user;
    name = serviceName;
    value = {
      description = "Reconcile managed systemd --user units for ${user}";
      unitConfig.ConditionUser = user;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Environment = [
          "PATH=${managedUserActionPath}"
          "SYSTEMD_USER_MANAGER_METADATA=${metadata.file}"
        ];
        TimeoutStartSec = 900;
        ExecStart = "${applyScript}";
      };
    };
  };

  userReconcilersByUser = lib.mapAttrs mkUserReconciler managedUnitsByUser;

  mkDispatcherService = user: userUnits: let
    userUid = userUidFor user;
    userAtService = "user@${toString userUid}.service";
    reconciler = userReconcilersByUser.${user};
    metadata = userMetadataByUser.${user};
    serviceName = dispatcherServiceNameForUser user;
    dispatcherScript = pkgs.writeShellScript "systemd-user-manager-${serviceName}-dispatch" ''
      set -eu
      mode="$1"
      metadata_file="''${SYSTEMD_USER_MANAGER_METADATA-${metadata.file}}"
      ${mkRootUserctlLib {
        user = user;
        userUid = userUid;
      }}

      metadata_path_from_unit_file() {
        local unit_file metadata_path
        unit_file="$1"
        [ -f "$unit_file" ] || return 1
        metadata_path="$(${pkgs.gnugrep}/bin/grep -Eo 'SYSTEMD_USER_MANAGER_METADATA=[^" ]+' "$unit_file" \
          | ${pkgs.coreutils}/bin/head -n1 \
          | ${pkgs.coreutils}/bin/cut -d= -f2-)"
        [ -n "$metadata_path" ] || return 1
        printf '%s\n' "$metadata_path"
      }

      userctl_load_state() {
        local unit out rc stdout_file stderr_file
        unit="$1"
        stdout_file="$(${pkgs.coreutils}/bin/mktemp)"
        stderr_file="$(${pkgs.coreutils}/bin/mktemp)"
        if userctl show --property=LoadState --value "$unit" >"$stdout_file" 2>"$stderr_file"; then
          out="$(${pkgs.coreutils}/bin/cat "$stdout_file")"
          ${pkgs.coreutils}/bin/rm -f "$stdout_file" "$stderr_file"
          printf '%s\n' "$out"
          return 0
        fi
        rc=$?
        out="$(${pkgs.coreutils}/bin/cat "$stderr_file")"
        ${pkgs.coreutils}/bin/rm -f "$stdout_file" "$stderr_file"
        case "$out" in
          *"not found"*|*"not be found"*|*"not loaded"*)
            printf '%s\n' "not-found"
            return 0
            ;;
        esac
        return "$rc"
      }

      stop_old_unit() {
        local managed_unit load_state
        managed_unit="$1"
        if ! ${pkgs.systemd}/bin/systemctl is-active --quiet ${lib.escapeShellArg userAtService}; then
          return 0
        fi
        if userctl stop "$managed_unit" >/dev/null 2>&1; then
          return 0
        fi
        load_state="$(userctl_load_state "$managed_unit")"
        [ "$load_state" = not-found ]
      }

      old_world_stop() {
        local new_metadata_file old_identity new_identity stop_failed
        new_metadata_file=""
        if new_metadata_file="$(metadata_path_from_unit_file /etc/systemd/system/${serviceName}.service 2>/dev/null)"; then
          :
        else
          new_metadata_file=""
        fi

        stop_failed=0
        while IFS=$'\t' read -r managed_name managed_unit stop_on_removal old_stamp; do
          new_stamp="$(${pkgs.jq}/bin/jq -r --arg name "$managed_name" '
            (.managedUnits // [])
            | map(select(.name == $name))
            | .[0].stamp // ""
          ' "$new_metadata_file" 2>/dev/null || true)"

          if [ -z "$new_stamp" ]; then
            if [ "$stop_on_removal" = 1 ]; then
              log_progress "stop-old: stopping removed managed unit $managed_unit for ${user}"
              if ! stop_old_unit "$managed_unit"; then
                stop_failed=1
              fi
            fi
            continue
          fi

          if [ "$old_stamp" != "$new_stamp" ]; then
            log_progress "stop-old: stopping changed managed unit $managed_unit for ${user}"
            if ! stop_old_unit "$managed_unit"; then
              stop_failed=1
            fi
          fi
        done < <(
          ${pkgs.jq}/bin/jq -r '.managedUnits[] | [.name, .unit, (if .stopOnRemoval then "1" else "0" end), .stamp] | @tsv' "$metadata_file"
        )

        if [ -n "$new_metadata_file" ] && [ -f "$new_metadata_file" ]; then
          old_identity="$(${pkgs.jq}/bin/jq -r '.identityStamp // ""' "$metadata_file")"
          new_identity="$(${pkgs.jq}/bin/jq -r '.identityStamp // ""' "$new_metadata_file")"
          if [ "$old_identity" != "$new_identity" ] && ${pkgs.systemd}/bin/systemctl is-active --quiet ${lib.escapeShellArg userAtService}; then
            log_progress "identity changed: restarting ${userAtService}"
            ${pkgs.systemd}/bin/systemctl restart ${lib.escapeShellArg userAtService}
          fi
        fi

        if [ "$stop_failed" -ne 0 ]; then
          return 1
        fi
      }

      wait_for_reconciler() {
        local unit previous_invocation current_invocation active_state sub_state result i log_pid
        unit="$1"
        previous_invocation="$(userctl show --property=InvocationID --value "$unit" 2>/dev/null || true)"
        userctl restart --no-block "$unit"

        current_invocation=""
        i=0
        while [ "$i" -lt 1800 ]; do
          current_invocation="$(userctl show --property=InvocationID --value "$unit" 2>/dev/null || true)"
          if [ -n "$current_invocation" ] && [ "$current_invocation" != "$previous_invocation" ]; then
            break
          fi
          ${pkgs.coreutils}/bin/sleep 0.5
          i=$((i + 1))
        done
        if [ -z "$current_invocation" ] || [ "$current_invocation" = "$previous_invocation" ]; then
          printf '%s\n' "[systemd-user-manager] timed out waiting for new invocation for $unit" >&2
          return 1
        fi

        ${pkgs.systemd}/bin/journalctl _SYSTEMD_INVOCATION_ID="$current_invocation" --no-pager -o cat --follow \
          | ${pkgs.gnugrep}/bin/grep --line-buffered -vE '^(Starting |Started |Finished |Stopped |systemd-user-manager-(dispatcher|reconciler)-.*: Deactivated successfully\.)' &
        log_pid=$!

        i=0
        while [ "$i" -lt 1800 ]; do
          active_state="$(userctl show --property=ActiveState --value "$unit" 2>/dev/null || true)"
          sub_state="$(userctl show --property=SubState --value "$unit" 2>/dev/null || true)"
          result="$(userctl show --property=Result --value "$unit" 2>/dev/null || true)"
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

      start_new_world() {
        log_progress "dispatcher start: user=${user}"
        ${pkgs.systemd}/bin/systemctl start ${lib.escapeShellArg userAtService}
        wait_for_user_manager
        userctl daemon-reload
        log_progress "dispatcher starting ${reconciler.serviceName}.service"
        wait_for_reconciler ${lib.escapeShellArg "${reconciler.serviceName}.service"}
        log_progress "dispatcher finished ${reconciler.serviceName}.service"
      }

      case "$mode" in
        start)
          start_new_world
          ;;
        stop)
          old_world_stop
          ;;
        *)
          printf '%s\n' "unknown dispatcher mode: $mode" >&2
          exit 1
          ;;
      esac
    '';
  in {
    name = serviceName;
    value = {
      description = "Dispatch managed systemd --user reconciliation for ${user}";
      after = [
        "multi-user.target"
        userAtService
      ];
      wantedBy = ["multi-user.target"];
      wants = [userAtService];
      restartTriggers = [
        metadata.hash
        reconciler.metadataHash
        reconciler.applyScript
      ];
      restartIfChanged = true;
      stopIfChanged = true;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Environment = [
          "SYSTEMD_USER_MANAGER_METADATA=${metadata.file}"
        ];
        TimeoutStartSec = 900;
        TimeoutStopSec = 900;
        ExecStart = "${dispatcherScript} start";
        ExecStop = "${dispatcherScript} stop";
      };
    };
  };

  dispatcherServicesByUser = lib.mapAttrs mkDispatcherService managedUnitsByUser;
in {
  options.services.systemdUserManager = {
    instances = lib.mkOption {
      type = lib.types.attrsOf unitType;
      default = {};
      description = ''
        Managed systemd --user units reconciled through one dispatcher and one
        user-side reconciler per user.
      '';
    };
  };

  config = {
    system.activationScripts.systemdUserManagerDispatcherRun = let
      managedUsers = builtins.attrNames dispatcherServicesByUser;
    in
      ''
        set -eu
        systemd_user_manager_dispatcher_run() {
          run_preview_as_user() {
            local managed_user managed_uid managed_gid managed_runtime_dir managed_bus script metadata_file
            managed_user="$1"
            managed_uid="$2"
            script="$3"
            metadata_file="$4"
            managed_gid="$(${pkgs.coreutils}/bin/id -g "$managed_user")"
            managed_runtime_dir="/run/user/$managed_uid"
            managed_bus="unix:path=$managed_runtime_dir/bus"
            ${pkgs.util-linux}/bin/setpriv \
              --reuid="$managed_user" \
              --regid="$managed_gid" \
              --init-groups \
              ${pkgs.coreutils}/bin/env \
                XDG_RUNTIME_DIR="$managed_runtime_dir" \
                DBUS_SESSION_BUS_ADDRESS="$managed_bus" \
                PATH=${lib.escapeShellArg managedUserActionPath} \
                SYSTEMD_USER_MANAGER_METADATA="$metadata_file" \
                DRY_RUN=1 \
                "$script"
          }

          case "''${NIXOS_ACTION-}" in
            switch|test)
              printf '%s\n' "[systemd-user-manager] activation hook skipped for action=''${NIXOS_ACTION-} (systemd handles dispatcher stop/start)"
              ;;
            dry-activate)
              printf '%s\n' "[systemd-user-manager] dry-activate preview start"
      ''
      + lib.concatStringsSep "\n"
      (map
        (user: let
          reconciler = userReconcilersByUser.${user};
        in ''
          printf '%s\n' "[systemd-user-manager] dry-activate preview ${reconciler.serviceName}.service"
          run_preview_as_user \
            ${lib.escapeShellArg user} \
            ${lib.escapeShellArg (toString (userUidFor user))} \
            ${lib.escapeShellArg reconciler.applyScript} \
            ${lib.escapeShellArg reconciler.metadataFile}
        '')
        managedUsers)
      + ''
              printf '%s\n' "[systemd-user-manager] dry-activate preview complete"
              ;;
            *)
              printf '%s\n' "[systemd-user-manager] activation hook skipped for action=''${NIXOS_ACTION-unknown}"
              ;;
          esac
        }
        systemd_user_manager_dispatcher_run
      '';

    assertions =
      [
        {
          assertion = duplicateGeneratedSystemdServiceNames == [];
          message = "services.systemdUserManager: duplicate generated systemd service names: ${lib.concatStringsSep ", " duplicateGeneratedSystemdServiceNames}";
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
      (builtins.attrValues dispatcherServicesByUser)
    );

    systemd.user.services = lib.listToAttrs (
      map
      (artifacts: {
        name = artifacts.name;
        value = artifacts.value;
      })
      (builtins.attrValues userReconcilersByUser)
    );

    systemd.user.targets.${lib.removeSuffix ".target" bootReadyTargetName} = {
      description = "Managed user units ready target";
    };
  };
}
