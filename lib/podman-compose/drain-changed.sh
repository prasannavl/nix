#!/usr/bin/env bash

set -Eeuo pipefail

log() {
	printf '[podman-drain] %s\n' "$*" >&2
}

run_as_user() {
	local user="$1" uid="$2" gid="$3"
	shift 3
	setpriv \
		--reuid="$user" \
		--regid="$gid" \
		--init-groups \
		env \
		XDG_RUNTIME_DIR="/run/user/$uid" \
		DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
		"$@"
}

unit_active_state() {
	local user="$1" uid="$2" gid="$3" unit="$4"
	run_as_user "$user" "$uid" "$gid" \
		systemctl --user show --property=ActiveState --value "$unit" 2>/dev/null || true
}

entry_needs_drain() {
	local service_name="$1" old_stamp="$2" removal_policy="$3"
	local new_entry new_stamp

	new_entry="$(jq -c --arg service "$service_name" '.[$service] // null' "$new_registry")"
	if [ "$new_entry" = null ]; then
		[ "$removal_policy" != keep ]
		return
	fi
	new_stamp="$(jq -r '.drainStamp // ""' <<<"$new_entry")"
	[ -z "$old_stamp" ] || [ "$old_stamp" != "$new_stamp" ]
}

drain_entry() {
	local service_name="$1" user="$2" uid="$3" unit="$4" old_stamp="$5" removal_policy="$6"
	local gid active_state

	entry_needs_drain "$service_name" "$old_stamp" "$removal_policy" || return 0
	if ! systemctl is-active --quiet "user@${uid}.service"; then
		log "user=$user unit=$unit skipped: user manager inactive"
		return 0
	fi
	if ! gid="$(id -g "$user")"; then
		log "user=$user unit=$unit failed: account unavailable"
		return 1
	fi
	active_state="$(unit_active_state "$user" "$uid" "$gid" "$unit")"
	case "$active_state" in
	active | activating | deactivating | reloading) ;;
	*) return 0 ;;
	esac

	log "user=$user unit=$unit action=draining"
	if ! run_as_user "$user" "$uid" "$gid" systemctl --user stop "$unit"; then
		log "user=$user unit=$unit drain failed; later units were left untouched"
		return 1
	fi
	log "user=$user unit=$unit drained"
}

drain_changed_units() {
	local row service_name user uid unit old_stamp removal_policy

	[ -f "$old_registry" ] || return 0
	[ -f "$new_registry" ] || {
		log "new control registry is missing: $new_registry"
		return 1
	}

	while IFS= read -r row; do
		[ -n "$row" ] || continue
		IFS=$'\t' read -r service_name user uid unit old_stamp removal_policy < <(
			printf '%s' "$row" | base64 -d | jq -r '[.key, .value.user, .value.uid, .value.unit, (.value.drainStamp // ""), (.value.removalPolicy // "stop")] | @tsv'
		)
		drain_entry "$service_name" "$user" "$uid" "$unit" "$old_stamp" "$removal_policy" || return 1
	done < <(jq -r 'to_entries | sort_by(.value.user, .key)[] | @base64' "$old_registry")
}

main() {
	old_registry="${NIX_PODMAN_COMPOSE_OLD_CONTROL_REGISTRY:-}"
	new_registry="${NIX_PODMAN_COMPOSE_NEW_CONTROL_REGISTRY:-}"
	if [ -z "$old_registry" ] || [ -z "$new_registry" ]; then
		printf '%s\n' 'NIX_PODMAN_COMPOSE_OLD_CONTROL_REGISTRY and NIX_PODMAN_COMPOSE_NEW_CONTROL_REGISTRY are required' >&2
		return 2
	fi
	drain_changed_units
}

main "$@"
