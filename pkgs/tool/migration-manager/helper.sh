#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	gate_path="${MIGRATION_MANAGER_GATE_PATH:-}"
	manifest_path="${MIGRATION_MANAGER_MANIFEST:-}"
	declared_state="${MIGRATION_MANAGER_DECLARED_STATE:-runtime}"
	[ -n "$gate_path" ] || {
		printf '%s\n' "missing MIGRATION_MANAGER_GATE_PATH" >&2
		exit 1
	}
}

log() {
	printf '%s\n' "[migration-manager] $*" >&2
}

ensure_gate_parent() {
	install -d -m 0755 "$(dirname "$gate_path")"
}

gate_is_on() {
	[ -f "$gate_path" ]
}

set_declared_gate_state() {
	ensure_gate_parent
	case "$declared_state" in
	runtime) ;;
	on | 1 | true | yes)
		: >"$gate_path"
		;;
	off | 0 | false | no)
		rm -f "$gate_path"
		;;
	*)
		printf '%s\n' "unsupported MIGRATION_MANAGER_DECLARED_STATE value: $declared_state" >&2
		exit 1
		;;
	esac
}

read_manifest_system_units() {
	local selector="$1"
	[ -n "$manifest_path" ] || {
		printf '%s\n' "missing MIGRATION_MANAGER_MANIFEST" >&2
		exit 1
	}
	jq -r --arg selector "$selector" '
    .systemUnits[]?
    | select(
        if $selector == "stop"
        then (if has("stopOnDrain") then .stopOnDrain else true end)
        else (if has("startOnResume") then .startOnResume else true end)
        end
      )
    | .unit
  ' "$manifest_path"
}

read_manifest_user_services() {
	[ -n "$manifest_path" ] || {
		printf '%s\n' "missing MIGRATION_MANAGER_MANIFEST" >&2
		exit 1
	}
	local selector="$1"
	jq -r --arg selector "$selector" '
    .userServices[]?
    | select(
        if $selector == "stop"
        then (if has("stopOnDrain") then .stopOnDrain else true end)
        else (if has("startOnResume") then .startOnResume else true end)
        end
      )
    | [.user, .unit]
    | @tsv
  ' "$manifest_path"
}

read_manifest_user_targets() {
	[ -n "$manifest_path" ] || {
		printf '%s\n' "missing MIGRATION_MANAGER_MANIFEST" >&2
		exit 1
	}
	local selector="$1"
	jq -r --arg selector "$selector" '
    .userTargets[]?
    | select(
        if $selector == "stop"
        then (if has("stopOnDrain") then .stopOnDrain else true end)
        else (if has("startOnResume") then .startOnResume else true end)
        end
      )
    | [.user, .target]
    | @tsv
  ' "$manifest_path"
}

unit_exists() {
	local unit="$1"
	local load_state=""
	load_state="$(systemctl show --property=LoadState --value "$unit" 2>/dev/null || true)"
	[ -n "$load_state" ] && [ "$load_state" != "not-found" ]
}

stop_system_units() {
	local unit=""
	local rc=0
	while IFS= read -r unit; do
		[ -n "$unit" ] || continue
		if ! unit_exists "$unit"; then
			continue
		fi
		log "stopping $unit"
		if ! systemctl stop --wait "$unit"; then
			log "failed to stop $unit"
			rc=1
		fi
	done < <(read_manifest_system_units stop)
	return "$rc"
}

start_system_units() {
	local unit=""
	local rc=0
	while IFS= read -r unit; do
		[ -n "$unit" ] || continue
		if ! unit_exists "$unit"; then
			continue
		fi
		log "starting $unit"
		if ! systemctl start "$unit"; then
			log "failed to start $unit"
			rc=1
		fi
	done < <(read_manifest_system_units start)
	return "$rc"
}

user_uid() {
	local user="$1"
	id -u "$user"
}

user_gid() {
	local user="$1"
	id -g "$user"
}

user_runtime_dir() {
	local user="$1" uid=""
	uid="$(user_uid "$user")"
	if [ "$(id -u)" = "$uid" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
		printf '%s\n' "$XDG_RUNTIME_DIR"
	else
		printf '/run/user/%s\n' "$uid"
	fi
}

run_user_systemctl() {
	local user="$1"
	shift
	local uid="" gid="" runtime_dir=""
	uid="$(user_uid "$user")"
	gid="$(user_gid "$user")"
	runtime_dir="$(user_runtime_dir "$user")"
	if [ "$(id -u)" = "$uid" ]; then
		XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus" systemctl --user "$@"
	else
		setpriv --reuid="$user" --regid="$gid" --init-groups env \
			XDG_RUNTIME_DIR="$runtime_dir" \
			DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus" \
			systemctl --user "$@"
	fi
}

user_unit_exists() {
	local user="$1" unit="$2"
	local load_state=""
	load_state="$(run_user_systemctl "$user" show --property=LoadState --value "$unit" 2>/dev/null || true)"
	[ -n "$load_state" ] && [ "$load_state" != "not-found" ]
}

stop_user_services() {
	local user="" unit=""
	local rc=0
	while IFS=$'\t' read -r user unit; do
		[ -n "$user" ] && [ -n "$unit" ] || continue
		if ! user_unit_exists "$user" "$unit"; then
			continue
		fi
		log "stopping user service $user:$unit"
		if ! run_user_systemctl "$user" stop --wait "$unit"; then
			log "failed to stop user service $user:$unit"
			rc=1
		fi
	done < <(read_manifest_user_services stop)
	return "$rc"
}

start_user_services() {
	local user="" unit=""
	local rc=0
	while IFS=$'\t' read -r user unit; do
		[ -n "$user" ] && [ -n "$unit" ] || continue
		if ! user_unit_exists "$user" "$unit"; then
			continue
		fi
		log "starting user service $user:$unit"
		if ! run_user_systemctl "$user" start "$unit"; then
			log "failed to start user service $user:$unit"
			rc=1
		fi
	done < <(read_manifest_user_services start)
	return "$rc"
}

stop_user_targets() {
	local user="" target=""
	local rc=0
	while IFS=$'\t' read -r user target; do
		[ -n "$user" ] && [ -n "$target" ] || continue
		if ! user_unit_exists "$user" "$target"; then
			continue
		fi
		log "stopping user target $user:$target"
		if ! run_user_systemctl "$user" stop --wait "$target"; then
			log "failed to stop user target $user:$target"
			rc=1
		fi
	done < <(read_manifest_user_targets stop)
	return "$rc"
}

start_user_targets() {
	local user="" target=""
	local rc=0
	while IFS=$'\t' read -r user target; do
		[ -n "$user" ] && [ -n "$target" ] || continue
		if ! user_unit_exists "$user" "$target"; then
			continue
		fi
		log "starting user target $user:$target"
		if ! run_user_systemctl "$user" start "$target"; then
			log "failed to start user target $user:$target"
			rc=1
		fi
	done < <(read_manifest_user_targets start)
	return "$rc"
}

apply_current_gate() {
	local rc=0
	if gate_is_on; then
		log "applying drain state: on"
		stop_system_units || rc=1
		stop_user_targets || rc=1
		stop_user_services || rc=1
	else
		log "applying drain state: off"
		start_system_units || rc=1
		start_user_services || rc=1
		start_user_targets || rc=1
	fi
	return "$rc"
}

main() {
	local action="${1:-}"
	init_vars

	case "$action" in
	apply)
		apply_current_gate
		;;
	sync)
		set_declared_gate_state
		;;
	*)
		printf '%s\n' "usage: migration-manager-helper {apply|sync}" >&2
		exit 1
		;;
	esac
}

main "$@"
