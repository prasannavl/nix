#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	gate_path="${MIGRATOR_GATE_PATH:?missing MIGRATOR_GATE_PATH}"
	manifest_path="${MIGRATOR_MANIFEST:-}"
	declared_state="${MIGRATOR_DECLARED_STATE:-${MIGRATOR_DECLARED_ON:-runtime}}"
}

log() {
	printf '%s\n' "[migrator] $*" >&2
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
		printf '%s\n' "unsupported MIGRATOR_DECLARED_STATE value: $declared_state" >&2
		exit 1
		;;
	esac
}

read_manifest_system_units() {
	local selector="$1"
	[ -n "$manifest_path" ] || {
		printf '%s\n' "missing MIGRATOR_MANIFEST" >&2
		exit 1
	}
	jq -r --arg selector "$selector" '
    .systemUnits[]?
    | select(
        if $selector == "stop"
        then (.stopOnDrain // true)
        else (.startOnResume // true)
      )
    | .unit
  ' "$manifest_path"
}

read_manifest_dispatcher_units() {
	[ -n "$manifest_path" ] || {
		printf '%s\n' "missing MIGRATOR_MANIFEST" >&2
		exit 1
	}
	jq -r '.dispatcherUnits[]?' "$manifest_path"
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

run_dispatchers() {
	local unit=""
	local rc=0
	while IFS= read -r unit; do
		[ -n "$unit" ] || continue
		if ! unit_exists "$unit"; then
			continue
		fi
		log "dispatching $unit"
		if ! systemctl restart "$unit"; then
			log "failed to dispatch $unit"
			rc=1
		fi
	done < <(read_manifest_dispatcher_units)
	return "$rc"
}

apply_current_gate() {
	local rc=0
	if gate_is_on; then
		log "applying drain state: on"
		stop_system_units || rc=1
	else
		log "applying drain state: off"
		start_system_units || rc=1
	fi
	run_dispatchers || rc=1
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
		printf '%s\n' "usage: migrator-helper {apply|sync}" >&2
		exit 1
		;;
	esac
}

main "$@"
