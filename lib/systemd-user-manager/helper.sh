#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	dry_run="${DRY_RUN-0}"
	userctl_mode=""

	systemd_user_manager_user="${SYSTEMD_USER_MANAGER_USER-}"
	systemd_user_manager_uid="${SYSTEMD_USER_MANAGER_UID-}"
	systemd_user_manager_metadata="${SYSTEMD_USER_MANAGER_METADATA-}"
	systemd_user_manager_reconciler_service="${SYSTEMD_USER_MANAGER_RECONCILER_SERVICE-}"
	systemd_user_manager_old_system="${SYSTEMD_USER_MANAGER_OLD_SYSTEM-}"
	systemd_user_manager_new_system="${SYSTEMD_USER_MANAGER_NEW_SYSTEM-}"
	systemd_user_manager_preview_manifest="${SYSTEMD_USER_MANAGER_PREVIEW_MANIFEST-}"

	managed_user_name=""
	managed_user_uid=""
	managed_user_gid=""
	managed_user_runtime_dir=""
	managed_user_bus=""

	managed_user_action_path="${SYSTEMD_USER_MANAGER_MANAGED_USER_ACTION_PATH-}"
	boot_ready_target_name="${SYSTEMD_USER_MANAGER_BOOT_READY_TARGET-}"
	applied_metadata_dir="${SYSTEMD_USER_MANAGER_APPLIED_METADATA_DIR-}"
	dispatcher_metadata_pointer_rel_dir="${SYSTEMD_USER_MANAGER_DISPATCHER_METADATA_POINTER_REL_DIR-}"
	deferred_restart_request_dir="${SYSTEMD_USER_MANAGER_DEFERRED_RESTART_REQUEST_DIR-}"
	deferred_unit_restart_request_dir="${SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RESTART_REQUEST_DIR-}"
	stable_state_timeout_seconds="${SYSTEMD_USER_MANAGER_STABLE_STATE_TIMEOUT_SECONDS:-120}"
}

require_env() {
	local name value
	name="$1"
	value="${!name-}"
	if [ -z "$value" ]; then
		printf '%s\n' "missing required environment variable: $name" >&2
		exit 1
	fi
}

log_progress() {
	printf '%s\n' "[systemd-user-manager] $*" >&2
}

log_user_progress() {
	local user message
	user="$1"
	message="$2"
	printf '[systemd-user-manager/%s] %s\n' "$user" "$message" >&2
}

log_managed_unit() {
	local user managed_name message
	user="$1"
	managed_name="$2"
	message="$3"
	printf '[systemd-user-manager/%s] %s: %s\n' "$user" "$managed_name" "$message" >&2
}

restart_request_marker_path() {
	local user sanitized_user
	user="$1"
	sanitized_user="${user//\//-}"
	printf '%s/%s' "$deferred_restart_request_dir" "$sanitized_user"
}

mark_deferred_user_manager_restart() {
	local user marker_path
	user="$1"
	require_env SYSTEMD_USER_MANAGER_DEFERRED_RESTART_REQUEST_DIR
	marker_path="$(restart_request_marker_path "$user")"
	mkdir -p "$deferred_restart_request_dir"
	printf '%s\n' "$user" >"$marker_path"
}

consume_deferred_user_manager_restart() {
	local user marker_path
	user="$1"
	require_env SYSTEMD_USER_MANAGER_DEFERRED_RESTART_REQUEST_DIR
	marker_path="$(restart_request_marker_path "$user")"
	if [ -f "$marker_path" ]; then
		rm -f "$marker_path"
		return 0
	fi
	return 1
}

managed_unit_restart_request_marker_path() {
	local user managed_name sanitized_user sanitized_name
	user="$1"
	managed_name="$2"
	sanitized_user="${user//\//-}"
	sanitized_name="${managed_name//\//-}"
	printf '%s/%s/%s' "$deferred_unit_restart_request_dir" "$sanitized_user" "$sanitized_name"
}

mark_deferred_managed_unit_restart() {
	local user managed_name marker_path marker_dir
	user="$1"
	managed_name="$2"
	require_env SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RESTART_REQUEST_DIR
	marker_path="$(managed_unit_restart_request_marker_path "$user" "$managed_name")"
	marker_dir="$(dirname "$marker_path")"
	mkdir -p "$marker_dir"
	printf '%s\n' "$managed_name" >"$marker_path"
}

consume_deferred_managed_unit_restart() {
	local user managed_name marker_path marker_dir
	user="$1"
	managed_name="$2"
	require_env SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RESTART_REQUEST_DIR
	marker_path="$(managed_unit_restart_request_marker_path "$user" "$managed_name")"
	marker_dir="$(dirname "$marker_path")"
	if [ -f "$marker_path" ]; then
		rm -f "$marker_path"
		rmdir "$marker_dir" 2>/dev/null || true
		return 0
	fi
	return 1
}

now_epoch() {
	date +%s
}

elapsed_since() {
	local start now
	start="$1"
	now="$(now_epoch)"
	printf '%ss' "$((now - start))"
}

is_transient_userctl_error() {
	printf '%s' "$1" | grep -Eq \
		'Transport endpoint is not connected|Failed to connect to bus|Connection refused|No such file or directory'
}

init_managed_user() {
	managed_user_name="$1"
	if ! managed_user_uid="$(id -u "$managed_user_name" 2>/dev/null)"; then
		return 1
	fi
	managed_user_gid="$(id -g "$managed_user_name")"
	managed_user_runtime_dir="/run/user/$managed_user_uid"
	managed_user_bus="unix:path=$managed_user_runtime_dir/bus"
}

init_managed_user_from_env() {
	require_env SYSTEMD_USER_MANAGER_USER
	require_env SYSTEMD_USER_MANAGER_UID

	managed_user_name="$systemd_user_manager_user"
	managed_user_uid="$systemd_user_manager_uid"
	managed_user_gid="$(id -g "$managed_user_name")"
	managed_user_runtime_dir="/run/user/$managed_user_uid"
	managed_user_bus="unix:path=$managed_user_runtime_dir/bus"
}

run_as_managed_user() {
	setpriv \
		--reuid="$managed_user_name" \
		--regid="$managed_user_gid" \
		--init-groups \
		env \
		XDG_RUNTIME_DIR="$managed_user_runtime_dir" \
		DBUS_SESSION_BUS_ADDRESS="$managed_user_bus" \
		"$@"
}

run_userctl_raw() {
	if [ "$userctl_mode" = root ]; then
		run_as_managed_user systemctl --user "$@"
	else
		systemctl --user "$@"
	fi
}

list_units_raw() {
	if [ "$userctl_mode" = root ]; then
		run_as_managed_user systemctl --user list-units --type=service --all --no-legend
	else
		systemctl --user list-units --type=service --all --no-legend
	fi
}

userctl_retry_context() {
	if [ "$userctl_mode" = root ]; then
		printf 'user=%s args=%s' "$managed_user_name" "$*"
	else
		printf 'args=%s' "$*"
	fi
}

userctl() {
	local out err rc i stdout_file stderr_file wait_logged retry_context
	i=0
	wait_logged=0
	retry_context="$(userctl_retry_context "$@")"
	while [ "$i" -lt 60 ]; do
		stdout_file="$(mktemp)"
		stderr_file="$(mktemp)"
		if run_userctl_raw "$@" >"$stdout_file" 2>"$stderr_file"; then
			out="$(cat "$stdout_file")"
			err="$(cat "$stderr_file")"
			rm -f "$stdout_file" "$stderr_file"
			[ -n "$err" ] && printf '%s\n' "$err" >&2
			[ -n "$out" ] && printf '%s\n' "$out"
			return 0
		fi
		rc=$?
		out="$(cat "$stderr_file")"
		rm -f "$stdout_file" "$stderr_file"
		if is_transient_userctl_error "$out"; then
			if [ "$wait_logged" -eq 0 ]; then
				log_progress "waiting for transient user-manager command retry: $retry_context"
				wait_logged=1
			fi
			i=$((i + 1))
			sleep 0.5
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
		out="$(list_units_raw 2>&1 >/dev/null)" && return 0
		rc=$?
		if is_transient_userctl_error "$out"; then
			if [ "$wait_logged" -eq 0 ]; then
				log_progress "waiting for user manager bus to become reachable"
				wait_logged=1
			fi
			i=$((i + 1))
			sleep 0.5
			continue
		fi
		[ -n "$out" ] && printf '%s\n' "$out" >&2
		return "$rc"
	done
	[ -n "$out" ] && printf '%s\n' "$out" >&2
	return "$rc"
}

userctl_load_state() {
	local unit out rc stdout_file stderr_file
	unit="$1"
	stdout_file="$(mktemp)"
	stderr_file="$(mktemp)"
	if userctl show --property=LoadState --value "$unit" >"$stdout_file" 2>"$stderr_file"; then
		out="$(cat "$stdout_file")"
		rm -f "$stdout_file" "$stderr_file"
		printf '%s\n' "$out"
		return 0
	fi
	rc=$?
	out="$(cat "$stderr_file")"
	rm -f "$stdout_file" "$stderr_file"
	case "$out" in
	*"not found"* | *"not be found"* | *"not loaded"*)
		printf '%s\n' "not-found"
		return 0
		;;
	esac
	return "$rc"
}

userctl_active_state() {
	local unit
	unit="$1"
	userctl show --property=ActiveState --value "$unit"
}

stop_managed_unit() {
	local managed_unit load_state stop_error
	managed_unit="$1"
	if ! systemctl is-active --quiet "user@${managed_user_uid}.service"; then
		return 0
	fi
	if stop_error="$(userctl stop "$managed_unit" 2>&1 >/dev/null)"; then
		return 0
	fi
	load_state="$(userctl_load_state "$managed_unit")"
	if [ "$load_state" = not-found ]; then
		return 0
	fi
	stop_error="${stop_error:-systemctl returned an error}"
	printf '%s\n' "[systemd-user-manager] failed to stop $managed_unit: $stop_error" >&2
	return 1
}

wait_for_unit_stopped_state() {
	local unit timeout_seconds load_state active_state sub_state result started_at now elapsed_seconds sleep_seconds
	unit="$1"
	timeout_seconds="${2:-$stable_state_timeout_seconds}"
	started_at="$(now_epoch)"
	while true; do
		load_state="$(userctl_load_state "$unit" 2>/dev/null || true)"
		if [ "$load_state" = not-found ]; then
			printf '%s\n' "not-found"
			return 0
		fi

		active_state="$(userctl show --property=ActiveState --value "$unit")"
		sub_state="$(userctl show --property=SubState --value "$unit")"
		result="$(userctl show --property=Result --value "$unit")"

		case "$active_state" in
		inactive | failed)
			printf '%s\n' "$active_state"
			return 0
			;;
		deactivating | activating | reloading)
			now="$(now_epoch)"
			elapsed_seconds="$((now - started_at))"
			if [ "$elapsed_seconds" -eq 0 ]; then
				log_progress "waiting for stopped state: unit=$unit current=$active_state sub=$sub_state"
			fi
			if [ "$elapsed_seconds" -ge "$timeout_seconds" ]; then
				printf '%s\n' "timed out waiting ${timeout_seconds}s for stopped state for $unit (active=$active_state sub=$sub_state result=$result)" >&2
				return 1
			fi
			sleep_seconds="$(stable_state_backoff_seconds "$elapsed_seconds")"
			sleep "$sleep_seconds"
			;;
		active)
			printf '%s\n' "unit $unit remained active after stop request (sub=$sub_state result=$result)" >&2
			return 1
			;;
		*)
			now="$(now_epoch)"
			elapsed_seconds="$((now - started_at))"
			if [ "$elapsed_seconds" -eq 0 ]; then
				log_progress "waiting for stopped state: unit=$unit current=$active_state sub=$sub_state"
			fi
			if [ "$elapsed_seconds" -ge "$timeout_seconds" ]; then
				printf '%s\n' "timed out waiting ${timeout_seconds}s for stopped state for $unit (active=$active_state sub=$sub_state result=$result)" >&2
				return 1
			fi
			sleep_seconds="$(stable_state_backoff_seconds "$elapsed_seconds")"
			sleep "$sleep_seconds"
			;;
		esac
	done
}

apply_stop_phase_action() {
	local phase_mode user managed_name managed_unit timeout_seconds stopped_state managed_stopped_at
	phase_mode="$1"
	user="$2"
	managed_name="$3"
	managed_unit="$4"
	timeout_seconds="${5:-$stable_state_timeout_seconds}"

	if [ "$phase_mode" = preview ]; then
		log_managed_unit "$user" "$managed_name" "would stop"
		return 0
	fi

	userctl_mode=root
	log_managed_unit "$user" "$managed_name" "stopping"
	if ! stop_managed_unit "$managed_unit"; then
		return 1
	fi
	managed_stopped_at="$(now_epoch)"
	if ! stopped_state="$(wait_for_unit_stopped_state "$managed_unit" "$timeout_seconds")"; then
		log_managed_unit "$user" "$managed_name" "failed to stop after $(elapsed_since "$managed_stopped_at")"
		return 1
	fi
	log_managed_unit "$user" "$managed_name" "stopped in $(elapsed_since "$managed_stopped_at") ($stopped_state)"
}

metadata_path_from_pointer_file() {
	local pointer_file metadata_path
	pointer_file="$1"
	[ -f "$pointer_file" ] || return 1
	metadata_path="$(tr -d '\n' <"$pointer_file")"
	[ -n "$metadata_path" ] || return 1
	printf '%s\n' "$metadata_path"
}

metadata_for_user_in_system() {
	local user system_path pointer_file metadata_file metadata_user
	user="$1"
	system_path="$2"
	for pointer_file in "$system_path"/etc/systemd-user-manager/dispatchers/*.metadata; do
		[ -e "$pointer_file" ] || continue
		metadata_file="$(metadata_path_from_pointer_file "$pointer_file" 2>/dev/null || true)"
		[ -n "$metadata_file" ] && [ -f "$metadata_file" ] || continue
		metadata_user="$(read_metadata_user "$metadata_file")"
		if [ "$metadata_user" = "$user" ]; then
			printf '%s\n' "$metadata_file"
			return 0
		fi
	done
	return 1
}

read_metadata_user() {
	local metadata_file="$1"

	jq -r '.user // ""' "$metadata_file"
}

is_valid_metadata_file() {
	local metadata_file="$1"

	jq --slurp -e 'length == 1 and (.[0] | type == "object" and (.managedUnits | type == "array"))' "$metadata_file" >/dev/null 2>&1
}

read_metadata_stop_state_tsv() {
	local metadata_file="$1"

	jq -r '
		(["metadata", (.version // 0), (.user // ""), (.identityStamp // "")] | @tsv),
		(.managedUnits[]? | [
			"unit",
			(.name // ""),
			(.unit // ""),
			(if .stopOnRemoval then "1" else "0" end),
			(.stamp // ""),
			(if .autoStart then "1" else "0" end),
			(.timeoutStableSeconds // 120)
		] | @tsv)
	' "$metadata_file"
}

read_empty_metadata_stop_state_tsv() {
	local user version identity_stamp
	user="$1"
	version="$2"
	identity_stamp="$3"

	empty_metadata_for_user "$user" "$version" "$identity_stamp" | jq -r '
		["metadata", (.version // 0), (.user // ""), (.identityStamp // "")] | @tsv
	'
}

read_metadata_units_tsv() {
	local metadata_file="$1"

	jq -r '.managedUnits[]? | [.name, .unit, (if .stopOnRemoval then "1" else "0" end), (.stamp // ""), (if .autoStart then "1" else "0" end), (.timeoutStableSeconds // 120)] | @tsv' "$metadata_file"
}

read_metadata_reconcile_units_tsv() {
	local metadata_file="$1"

	jq -r '.managedUnits | sort_by(.name)[] | [.name, .unit, (if .autoStart then "1" else "0" end), (.timeoutStableSeconds // 120)] | @tsv' "$metadata_file"
}

metadata_header_from_stop_state_tsv() {
	local metadata_tsv record version user identity_stamp
	metadata_tsv="$1"

	while IFS=$'\t' read -r record version user identity_stamp; do
		if [ "$record" = metadata ]; then
			printf '%s\t%s\t%s\n' "$version" "$user" "$identity_stamp"
			return 0
		fi
	done <<<"$metadata_tsv"
	return 1
}

applied_metadata_path() {
	local user sanitized_user
	user="$1"
	require_env SYSTEMD_USER_MANAGER_APPLIED_METADATA_DIR
	sanitized_user="${user//\//-}"
	printf '%s/%s.json' "$applied_metadata_dir" "$sanitized_user"
}

store_applied_metadata() {
	local user metadata_file state_file
	user="$1"
	metadata_file="$2"
	state_file="$(applied_metadata_path "$user")"
	mkdir -p "$applied_metadata_dir"
	(
		local tmp_file
		tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
		trap 'rm -f "$tmp_file"' EXIT
		cp "$metadata_file" "$tmp_file"
		mv "$tmp_file" "$state_file"
	)
}

empty_metadata_for_user() {
	local user version identity_stamp
	user="$1"
	version="${2:-0}"
	identity_stamp="${3:-}"
	jq -cn \
		--arg user "$user" \
		--arg identityStamp "$identity_stamp" \
		--argjson version "$version" \
		'{version: $version, user: $user, identityStamp: $identityStamp, managedUnits: []}'
}

diff_and_stop_units() {
	local phase_mode user old_metadata_tsv new_metadata_tsv
	local stop_failed=0 new_name="" new_stamp="" new_auto_start="" new_timeout="" managed_name="" managed_unit="" stop_on_removal="" old_stamp="" managed_timeout=""
	local active_state_before_stop="" old_identity="" new_identity=""
	local record="" old_header="" new_header="" _old_version="" _old_user="" _new_version="" _new_user=""
	local changed_stop_timeout=""
	local new_metadata_present=0
	local -A new_stamps_by_name=()
	local -A new_auto_start_by_name=()
	local -A new_timeouts_by_name=()

	phase_mode="$1"
	user="$2"
	old_metadata_tsv="$3"
	new_metadata_tsv="$4"

	if ! old_header="$(metadata_header_from_stop_state_tsv "$old_metadata_tsv")"; then
		printf '%s\n' "[systemd-user-manager] failed to read old metadata header for user: $user" >&2
		return 1
	fi
	IFS=$'\t' read -r _old_version _old_user old_identity <<<"$old_header"
	if [ -n "$new_metadata_tsv" ]; then
		new_metadata_present=1
		if ! new_header="$(metadata_header_from_stop_state_tsv "$new_metadata_tsv")"; then
			printf '%s\n' "[systemd-user-manager] failed to read new metadata header for user: $user" >&2
			return 1
		fi
		IFS=$'\t' read -r _new_version _new_user new_identity <<<"$new_header"
		while IFS=$'\t' read -r record new_name _ _ new_stamp new_auto_start new_timeout; do
			[ "$record" = unit ] || continue
			[ -n "$new_name" ] || continue
			new_stamps_by_name["$new_name"]="$new_stamp"
			new_auto_start_by_name["$new_name"]="$new_auto_start"
			new_timeouts_by_name["$new_name"]="$new_timeout"
		done <<<"$new_metadata_tsv"
	fi

	if [ -n "$old_metadata_tsv" ]; then
		while IFS=$'\t' read -r record managed_name managed_unit stop_on_removal old_stamp new_auto_start managed_timeout; do
			[ "$record" = unit ] || continue
			new_stamp="${new_stamps_by_name["$managed_name"]-}"
			new_auto_start="${new_auto_start_by_name["$managed_name"]-1}"

			if [ -z "$new_stamp" ]; then
				if [ "$stop_on_removal" = 1 ]; then
					if ! apply_stop_phase_action "$phase_mode" "$user" "$managed_name" "$managed_unit" "$managed_timeout"; then
						stop_failed=1
					fi
				fi
				continue
			fi

			if [ "$old_stamp" != "$new_stamp" ]; then
				changed_stop_timeout="${new_timeouts_by_name["$managed_name"]-$managed_timeout}"
				if [ "$phase_mode" = apply ] && [ "$new_auto_start" != 1 ]; then
					userctl_mode=root
					active_state_before_stop="$(userctl_active_state "$managed_unit" 2>/dev/null || true)"
					case "$active_state_before_stop" in
					active | activating | deactivating | reloading)
						mark_deferred_managed_unit_restart "$user" "$managed_name"
						;;
					esac
				fi
				if ! apply_stop_phase_action "$phase_mode" "$user" "$managed_name" "$managed_unit" "$changed_stop_timeout"; then
					stop_failed=1
				fi
			fi
		done <<<"$old_metadata_tsv"
	fi

	if [ "$phase_mode" = apply ] && [ "$stop_failed" -ne 0 ]; then
		return 1
	fi
	if [ "$new_metadata_present" -eq 1 ] && [ "$old_identity" != "$new_identity" ]; then
		if [ "$phase_mode" = preview ]; then
			log_user_progress "$user" "would restart user manager"
		else
			log_user_progress "$user" "deferring user manager restart to dispatcher"
			mark_deferred_user_manager_restart "$user"
		fi
	fi
	return 0
}

stop_changed_managed_units_from_applied_metadata() {
	local state_file state_metadata_tsv="" new_metadata_tsv=""
	local state_header="" new_header="" old_version="" new_version=""
	require_env SYSTEMD_USER_MANAGER_METADATA
	state_file="$(applied_metadata_path "$systemd_user_manager_user")"
	if [ ! -f "$state_file" ]; then
		stop_active_managed_units_without_applied_metadata
		return
	fi
	if ! is_valid_metadata_file "$state_file"; then
		printf '%s\n' "[systemd-user-manager] discarding malformed applied metadata: $state_file" >&2
		rm -f "$state_file"
		stop_active_managed_units_without_applied_metadata
		return
	fi
	if ! state_metadata_tsv="$(read_metadata_stop_state_tsv "$state_file")"; then
		printf '%s\n' "[systemd-user-manager] failed to read applied metadata: $state_file" >&2
		return 1
	fi
	if ! state_header="$(metadata_header_from_stop_state_tsv "$state_metadata_tsv")"; then
		printf '%s\n' "[systemd-user-manager] failed to read applied metadata header: $state_file" >&2
		return 1
	fi
	IFS=$'\t' read -r old_version _ _ <<<"$state_header"
	if ! new_metadata_tsv="$(read_metadata_stop_state_tsv "$systemd_user_manager_metadata")"; then
		printf '%s\n' "[systemd-user-manager] failed to read managed units metadata: $systemd_user_manager_metadata" >&2
		return 1
	fi
	if ! new_header="$(metadata_header_from_stop_state_tsv "$new_metadata_tsv")"; then
		printf '%s\n' "[systemd-user-manager] failed to read metadata header: $systemd_user_manager_metadata" >&2
		return 1
	fi
	IFS=$'\t' read -r new_version _ _ <<<"$new_header"
	if [ "$old_version" != "$new_version" ]; then
		log_user_progress "$systemd_user_manager_user" "applied metadata version changed; running fresh reconcile"
		stop_active_managed_units_without_applied_metadata
		return
	fi
	diff_and_stop_units apply "$systemd_user_manager_user" "$state_metadata_tsv" "$new_metadata_tsv"
}

stop_active_managed_units_without_applied_metadata() {
	local managed_units_tsv="" managed_name="" managed_unit="" auto_start="" managed_timeout="" active_state="" stop_failed=0
	require_env SYSTEMD_USER_MANAGER_METADATA
	if ! managed_units_tsv="$(read_metadata_units_tsv "$systemd_user_manager_metadata")"; then
		printf '%s\n' "[systemd-user-manager] failed to read managed units metadata: $systemd_user_manager_metadata" >&2
		return 1
	fi
	[ -n "$managed_units_tsv" ] || return 0
	while IFS=$'\t' read -r managed_name managed_unit _ _ auto_start managed_timeout; do
		[ -n "$managed_name" ] || continue
		active_state="$(userctl_active_state "$managed_unit" 2>/dev/null || true)"
		case "$active_state" in
		active | activating | deactivating | reloading) ;;
		*)
			continue
			;;
		esac
		if [ "$auto_start" != 1 ]; then
			mark_deferred_managed_unit_restart "$systemd_user_manager_user" "$managed_name"
		fi
		if ! apply_stop_phase_action apply "$systemd_user_manager_user" "$managed_name" "$managed_unit" "$managed_timeout"; then
			stop_failed=1
		fi
	done <<<"$managed_units_tsv"
	[ "$stop_failed" -eq 0 ]
}

stable_state_backoff_seconds() {
	local elapsed_seconds
	elapsed_seconds="$1"
	case "$elapsed_seconds" in
	0 | 1)
		printf '%s\n' "0.5"
		;;
	2 | 3)
		printf '%s\n' "1"
		;;
	4 | 5 | 6 | 7)
		printf '%s\n' "2"
		;;
	*)
		printf '%s\n' "5"
		;;
	esac
}

unit_stable_state() {
	local unit timeout_seconds active_state sub_state result started_at now elapsed_seconds sleep_seconds
	unit="$1"
	timeout_seconds="${2:-$stable_state_timeout_seconds}"
	started_at="$(now_epoch)"
	while true; do
		active_state="$(userctl show --property=ActiveState --value "$unit")"
		sub_state="$(userctl show --property=SubState --value "$unit")"
		result="$(userctl show --property=Result --value "$unit")"
		case "$active_state" in
		activating | deactivating | reloading)
			now="$(now_epoch)"
			elapsed_seconds="$((now - started_at))"
			if [ "$sub_state" = auto-restart ] || [ "$result" = failed ]; then
				printf '%s\n' "unit $unit entered transitional failure state active=$active_state sub=$sub_state result=$result" >&2
				return 1
			fi
			if [ "$elapsed_seconds" -eq 0 ]; then
				log_progress "waiting for stable state: unit=$unit current=$active_state sub=$sub_state"
			fi
			if [ "$elapsed_seconds" -ge "$timeout_seconds" ]; then
				printf '%s\n' "timed out waiting ${timeout_seconds}s for stable ActiveState for $unit (active=$active_state sub=$sub_state result=$result)" >&2
				return 1
			fi
			sleep_seconds="$(stable_state_backoff_seconds "$elapsed_seconds")"
			sleep "$sleep_seconds"
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

journal_replay_line_is_noise() {
	local line="$1"
	local journal_noise_re='^(Starting |Started |Finished |Stopped |systemd-user-manager-(dispatcher|reconciler)-.*: Deactivated successfully\.)'

	[[ "$line" =~ $journal_noise_re ]]
}

emit_journal_file_lines() {
	local journal_file="$1" line=""

	[ -s "$journal_file" ] || return 0

	while IFS= read -r line || [ -n "$line" ]; do
		if journal_replay_line_is_noise "$line"; then
			continue
		fi
		printf '%s\n' "$line"
	done <"$journal_file"
}

emit_new_journal() {
	local cursor_file="$1"
	shift
	local tmp_file="" content_file="" last_line="" cursor="" journalctl_rc=0

	tmp_file="$(mktemp)"
	if [ -s "$cursor_file" ]; then
		if timeout 1s \
			journalctl \
			--after-cursor "$(cat "$cursor_file")" \
			--show-cursor \
			--no-pager \
			-o cat \
			"$@" >"$tmp_file" 2>/dev/null; then
			:
		else
			journalctl_rc=$?
		fi
	else
		if timeout 1s \
			journalctl \
			--show-cursor \
			--no-pager \
			-o cat \
			"$@" >"$tmp_file" 2>/dev/null; then
			:
		else
			journalctl_rc=$?
		fi
	fi

	if [ "$journalctl_rc" -eq 124 ]; then
		rm -f "$tmp_file"
		return 124
	fi

	if [ ! -s "$tmp_file" ]; then
		rm -f "$tmp_file"
		return 1
	fi

	content_file="$tmp_file"
	last_line="$(tail -n 1 "$tmp_file")"
	if [[ "$last_line" == --\ cursor:\ * ]]; then
		cursor="${last_line#-- cursor: }"
		printf '%s\n' "$cursor" >"$cursor_file"
		content_file="$(mktemp)"
		sed '$d' "$tmp_file" >"$content_file"
		rm -f "$tmp_file"
	fi

	emit_journal_file_lines "$content_file"
	rm -f "$content_file"
	return 0
}

start_managed_unit() {
	local managed_name managed_unit auto_start timeout_seconds active_state unit_file_state managed_started_at
	managed_name="$1"
	managed_unit="$2"
	auto_start="$3"
	timeout_seconds="${4:-$stable_state_timeout_seconds}"
	managed_unit_outcome="noop"
	managed_unit_start_pid=""
	managed_unit_start_started_at=""
	managed_started_at="$(now_epoch)"

	if ! active_state="$(unit_stable_state "$managed_unit" "$timeout_seconds")"; then
		log_managed_unit "$systemd_user_manager_user" "$managed_name" "failed after $(elapsed_since "$managed_started_at")"
		managed_unit_outcome="fail"
		return 1
	fi

	case "$active_state" in
	active)
		return 0
		;;
	inactive | failed)
		unit_file_state="$(userctl_unit_file_state "$managed_unit")"
		case "$unit_file_state" in
		disabled | masked | masked-runtime)
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "skipped ($unit_file_state)"
			managed_unit_outcome="skip"
			return 0
			;;
		esac
		if [ "$auto_start" != 1 ] && ! consume_deferred_managed_unit_restart "$systemd_user_manager_user" "$managed_name"; then
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "skipped (autoStart=false)"
			managed_unit_outcome="skip"
			return 0
		fi
		managed_unit_outcome="start"
		if [ "$dry_run" = 1 ]; then
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "would start"
		else
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "starting"
			(
				userctl start "$managed_unit"
			) &
			managed_unit_start_pid=$!
			managed_unit_start_started_at="$managed_started_at"
		fi
		return 0
		;;
	*)
		printf '%s\n' "unexpected stable ActiveState for $managed_unit: $active_state" >&2
		return 1
		;;
	esac
}

wait_for_reconciler() {
	local unit previous_invocation current_invocation active_state sub_state result i
	local journal_cursor_file="" wait_started_at=""
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
		sleep 0.5
		i=$((i + 1))
	done
	if [ -z "$current_invocation" ] || [ "$current_invocation" = "$previous_invocation" ]; then
		printf '%s\n' "[systemd-user-manager] timed out waiting for new invocation for $unit" >&2
		return 1
	fi

	wait_started_at="$(now_epoch)"
	journal_cursor_file="$(mktemp)"
	trap 'rm -f "$journal_cursor_file"' RETURN
	i=0
	while [ "$i" -lt 1800 ]; do
		if [ $((i % 4)) -eq 0 ]; then
			emit_new_journal "$journal_cursor_file" "_SYSTEMD_INVOCATION_ID=$current_invocation" || true
		fi

		active_state="$(userctl show --property=ActiveState --value "$unit" 2>/dev/null || true)"
		sub_state="$(userctl show --property=SubState --value "$unit" 2>/dev/null || true)"
		result="$(userctl show --property=Result --value "$unit" 2>/dev/null || true)"
		case "$active_state:$sub_state:$result" in
		active:exited:success | inactive:dead:success)
			break
			;;
		failed:failed:* | inactive:dead:failed)
			break
			;;
		esac
		if [ $((i % 30)) -eq 0 ] && [ "$i" -gt 0 ]; then
			log_user_progress "$systemd_user_manager_user" "still waiting; elapsed=$(elapsed_since "$wait_started_at")"
		fi
		sleep 0.5
		i=$((i + 1))
	done

	emit_new_journal "$journal_cursor_file" "_SYSTEMD_INVOCATION_ID=$current_invocation" || true
	rm -f "$journal_cursor_file"
	journal_cursor_file=""
	trap - RETURN

	case "$active_state:$sub_state:$result" in
	active:exited:success | inactive:dead:success)
		return 0
		;;
	failed:failed:* | inactive:dead:failed)
		return 1
		;;
	esac

	printf '%s\n' "[systemd-user-manager] timed out waiting for $unit" >&2
	return 1
}

run_reconciler_apply() {
	local failed_units apply_started_at total_units work_units skipped_units
	local i finished_pid="" managed_name="" managed_started_at="" managed_pid=""
	local managed_units_tsv=""
	local -a started_unit_names started_unit_pids started_unit_started_ats
	local -a pending_unit_start_pids next_pending_unit_start_pids
	local -A started_unit_names_by_pid started_unit_started_ats_by_pid

	require_env SYSTEMD_USER_MANAGER_USER
	require_env SYSTEMD_USER_MANAGER_METADATA

	userctl_mode=user
	failed_units=""
	total_units=0
	work_units=0
	skipped_units=0
	started_unit_names=()
	started_unit_pids=()
	started_unit_started_ats=()
	apply_started_at="$(now_epoch)"

	if ! wait_for_user_manager; then
		if [ "$dry_run" = 1 ]; then
			log_progress "dry-activate: user manager for $systemd_user_manager_user is not reachable; skipping preview"
			exit 0
		fi
		exit 1
	fi

	if [ "$dry_run" != 1 ]; then
		userctl daemon-reload
	fi

	log_user_progress "$systemd_user_manager_user" "reconcile starting"
	if ! managed_units_tsv="$(read_metadata_reconcile_units_tsv "$systemd_user_manager_metadata")"; then
		printf '%s\n' "[systemd-user-manager] failed to read managed units metadata: $systemd_user_manager_metadata" >&2
		exit 1
	fi
	if [ -n "$managed_units_tsv" ]; then
		while IFS=$'\t' read -r managed_name managed_unit auto_start managed_timeout; do
			total_units=$((total_units + 1))
			if ! start_managed_unit "$managed_name" "$managed_unit" "$auto_start" "$managed_timeout"; then
				failed_units="${failed_units} ${managed_name}"
			elif [ "$managed_unit_outcome" = "start" ]; then
				work_units=$((work_units + 1))
				if [ -n "$managed_unit_start_pid" ]; then
					started_unit_names+=("$managed_name")
					started_unit_pids+=("$managed_unit_start_pid")
					started_unit_started_ats+=("$managed_unit_start_started_at")
				fi
			elif [ "$managed_unit_outcome" = "skip" ]; then
				skipped_units=$((skipped_units + 1))
			fi
		done <<<"$managed_units_tsv"
	fi

	if [ "$dry_run" != 1 ] && [ "${#started_unit_pids[@]}" -gt 0 ]; then
		for i in "${!started_unit_pids[@]}"; do
			started_unit_names_by_pid["${started_unit_pids[$i]}"]="${started_unit_names[$i]}"
			started_unit_started_ats_by_pid["${started_unit_pids[$i]}"]="${started_unit_started_ats[$i]}"
		done
		pending_unit_start_pids=("${started_unit_pids[@]}")
		while [ "${#pending_unit_start_pids[@]}" -gt 0 ]; do
			finished_pid=""
			# wait -p needs Bash >= 5.1; this helper runs through nixpkgs bash.
			if wait -n -p finished_pid "${pending_unit_start_pids[@]}"; then
				managed_name="${started_unit_names_by_pid[$finished_pid]-}"
				managed_started_at="${started_unit_started_ats_by_pid[$finished_pid]-}"
				if [ -z "$managed_name" ] || [ -z "$managed_started_at" ]; then
					printf '%s\n' "[systemd-user-manager] unexpected wait result for managed unit start pid=${finished_pid:-unknown}" >&2
					exit 1
				fi
				log_managed_unit "$systemd_user_manager_user" "$managed_name" "started in $(elapsed_since "$managed_started_at")"
			else
				managed_name="${started_unit_names_by_pid[$finished_pid]-}"
				managed_started_at="${started_unit_started_ats_by_pid[$finished_pid]-}"
				if [ -z "$managed_name" ] || [ -z "$managed_started_at" ]; then
					printf '%s\n' "[systemd-user-manager] unexpected failed wait result for managed unit start pid=${finished_pid:-unknown}" >&2
					exit 1
				fi
				log_managed_unit "$systemd_user_manager_user" "$managed_name" "failed to start after $(elapsed_since "$managed_started_at")"
				failed_units="${failed_units} ${managed_name}"
			fi

			next_pending_unit_start_pids=()
			for managed_pid in "${pending_unit_start_pids[@]}"; do
				[ "$managed_pid" = "$finished_pid" ] && continue
				next_pending_unit_start_pids+=("$managed_pid")
			done
			pending_unit_start_pids=("${next_pending_unit_start_pids[@]}")
			unset "started_unit_names_by_pid[$finished_pid]" "started_unit_started_ats_by_pid[$finished_pid]"
		done
	fi

	if [ -n "$failed_units" ]; then
		if [ "$dry_run" = 1 ]; then
			log_user_progress "$systemd_user_manager_user" "preview failed after $(elapsed_since "$apply_started_at"): failed_units=$failed_units"
		else
			log_user_progress "$systemd_user_manager_user" "reconcile failed after $(elapsed_since "$apply_started_at"): failed_units=$failed_units"
		fi
		printf '%s\n' "failed managed units:$failed_units" >&2
		exit 1
	fi

	if [ "$dry_run" != 1 ]; then
		userctl start "$boot_ready_target_name"
	elif [ "$work_units" -gt 0 ] || [ "$skipped_units" -gt 0 ]; then
		log_user_progress "$systemd_user_manager_user" "would start $boot_ready_target_name"
	fi

	if [ "$work_units" -gt 0 ] || [ "$skipped_units" -gt 0 ]; then
		if [ "$dry_run" = 1 ]; then
			log_user_progress "$systemd_user_manager_user" "preview done in $(elapsed_since "$apply_started_at"), would_start=$work_units skipped=$skipped_units"
		else
			log_user_progress "$systemd_user_manager_user" "reconcile done in $(elapsed_since "$apply_started_at"), started=$work_units skipped=$skipped_units"
		fi
	elif [ "$dry_run" = 1 ]; then
		log_user_progress "$systemd_user_manager_user" "preview noop in $(elapsed_since "$apply_started_at"), managed=$total_units"
	else
		log_user_progress "$systemd_user_manager_user" "reconcile noop in $(elapsed_since "$apply_started_at"), managed=$total_units"
	fi
}

run_dispatcher_start() {
	init_managed_user_from_env
	require_env SYSTEMD_USER_MANAGER_RECONCILER_SERVICE

	userctl_mode=root

	log_user_progress "$systemd_user_manager_user" "dispatcher starting"
	if consume_deferred_user_manager_restart "$systemd_user_manager_user"; then
		log_user_progress "$systemd_user_manager_user" "restarting user manager"
		systemctl restart "user@${managed_user_uid}.service"
	else
		systemctl start "user@${managed_user_uid}.service"
	fi
	wait_for_user_manager
	stop_changed_managed_units_from_applied_metadata
	userctl daemon-reload
	wait_for_reconciler "$systemd_user_manager_reconciler_service"
	store_applied_metadata "$systemd_user_manager_user" "$systemd_user_manager_metadata"
	log_user_progress "$systemd_user_manager_user" "dispatcher finished"
}

run_metadata_pointer_stop_phase() {
	local phase_mode old_units_dir old_pointer_dir old_unit_file old_service_name old_pointer_file
	local new_pointer_file old_metadata_file new_metadata_file old_metadata_tsv="" new_metadata_tsv=""
	local old_header="" old_version="" old_user="" new_header="" new_version="" skipped_users=""

	phase_mode="$1"
	skipped_users="${2-}"
	old_units_dir="${systemd_user_manager_old_system}/etc/systemd/system"
	old_pointer_dir="${systemd_user_manager_old_system}/etc/${dispatcher_metadata_pointer_rel_dir}"
	[ -d "$old_units_dir" ] || return 0

	for old_unit_file in "$old_units_dir"/systemd-user-manager-dispatcher-*.service; do
		[ -e "$old_unit_file" ] || continue
		old_service_name="$(basename "$old_unit_file" .service)"
		old_pointer_file="$old_pointer_dir/$old_service_name.metadata"
		new_pointer_file="${systemd_user_manager_new_system}/etc/${dispatcher_metadata_pointer_rel_dir}/$old_service_name.metadata"
		old_metadata_file="$(metadata_path_from_pointer_file "$old_pointer_file" 2>/dev/null || true)"
		[ -n "$old_metadata_file" ] || continue
		new_metadata_file="$(metadata_path_from_pointer_file "$new_pointer_file" 2>/dev/null || true)"
		if ! old_metadata_tsv="$(read_metadata_stop_state_tsv "$old_metadata_file")"; then
			printf '%s\n' "[systemd-user-manager] failed to read managed units metadata: $old_metadata_file" >&2
			return 1
		fi
		if ! old_header="$(metadata_header_from_stop_state_tsv "$old_metadata_tsv")"; then
			printf '%s\n' "[systemd-user-manager] failed to read metadata header: $old_metadata_file" >&2
			return 1
		fi
		IFS=$'\t' read -r old_version old_user _ <<<"$old_header"
		[ -n "$old_user" ] || continue
		if [ -n "$skipped_users" ] && grep -Fxq -- "$old_user" <<<"$skipped_users"; then
			continue
		fi

		if [ "$phase_mode" = apply ]; then
			if ! init_managed_user "$old_user"; then
				log_user_progress "$old_user" "stop skipped: account unavailable"
				continue
			fi
		fi

		new_metadata_tsv=""
		new_header=""
		new_version=""
		if [ -n "$new_metadata_file" ] && [ -f "$new_metadata_file" ]; then
			if ! new_metadata_tsv="$(read_metadata_stop_state_tsv "$new_metadata_file")"; then
				printf '%s\n' "[systemd-user-manager] failed to read managed units metadata: $new_metadata_file" >&2
				return 1
			fi
			if ! new_header="$(metadata_header_from_stop_state_tsv "$new_metadata_tsv")"; then
				printf '%s\n' "[systemd-user-manager] failed to read metadata header: $new_metadata_file" >&2
				return 1
			fi
			IFS=$'\t' read -r new_version _ _ <<<"$new_header"
			if [ "$old_version" != "$new_version" ]; then
				log_user_progress "$old_user" "stop skipped: metadata version changed"
				continue
			fi
		fi
		if ! diff_and_stop_units "$phase_mode" "$old_user" "$old_metadata_tsv" "$new_metadata_tsv"; then
			return 1
		fi
	done
}

run_preview_as_user() {
	local preview_user preview_metadata preview_reconciler_service
	preview_user="$1"
	preview_metadata="$2"
	preview_reconciler_service="$3"

	init_managed_user "$preview_user"
	printf '%s\n' "[systemd-user-manager] dry-activate preview $preview_reconciler_service"
	run_as_managed_user \
		env \
		PATH="$managed_user_action_path" \
		SYSTEMD_USER_MANAGER_USER="$preview_user" \
		SYSTEMD_USER_MANAGER_METADATA="$preview_metadata" \
		DRY_RUN=1 \
		"$0" reconciler-apply
}

run_activation_stop_applied() {
	local state_file old_user new_metadata_file
	local state_metadata_tsv="" state_header="" old_version="" old_identity=""
	local new_metadata_tsv="" new_header="" new_version=""
	local applied_users=""
	require_env SYSTEMD_USER_MANAGER_NEW_SYSTEM
	require_env SYSTEMD_USER_MANAGER_OLD_SYSTEM
	require_env SYSTEMD_USER_MANAGER_APPLIED_METADATA_DIR

	if [ ! -d "$applied_metadata_dir" ]; then
		run_metadata_pointer_stop_phase apply
		return
	fi
	for state_file in "$applied_metadata_dir"/*.json; do
		[ -e "$state_file" ] || continue
		if ! is_valid_metadata_file "$state_file"; then
			printf '%s\n' "[systemd-user-manager] discarding malformed applied metadata: $state_file" >&2
			rm -f "$state_file"
			continue
		fi
		if ! state_metadata_tsv="$(read_metadata_stop_state_tsv "$state_file")"; then
			printf '%s\n' "[systemd-user-manager] failed to read applied metadata: $state_file" >&2
			return 1
		fi
		if ! state_header="$(metadata_header_from_stop_state_tsv "$state_metadata_tsv")"; then
			printf '%s\n' "[systemd-user-manager] failed to read applied metadata header: $state_file" >&2
			return 1
		fi
		IFS=$'\t' read -r old_version old_user old_identity <<<"$state_header"
		[ -n "$old_user" ] || continue
		applied_users="${applied_users}${old_user}"$'\n'
		if ! init_managed_user "$old_user"; then
			log_user_progress "$old_user" "stop skipped: account unavailable"
			continue
		fi
		new_metadata_file="$(metadata_for_user_in_system "$old_user" "$systemd_user_manager_new_system" 2>/dev/null || true)"
		if [ -n "$new_metadata_file" ]; then
			if ! new_metadata_tsv="$(read_metadata_stop_state_tsv "$new_metadata_file")"; then
				printf '%s\n' "[systemd-user-manager] failed to read managed units metadata: $new_metadata_file" >&2
				return 1
			fi
			if ! new_header="$(metadata_header_from_stop_state_tsv "$new_metadata_tsv")"; then
				printf '%s\n' "[systemd-user-manager] failed to read metadata header: $new_metadata_file" >&2
				return 1
			fi
			IFS=$'\t' read -r new_version _ _ <<<"$new_header"
			if [ "$old_version" != "$new_version" ]; then
				log_user_progress "$old_user" "stop skipped: applied metadata version changed"
				continue
			fi
			if ! diff_and_stop_units apply "$old_user" "$state_metadata_tsv" "$new_metadata_tsv"; then
				return 1
			fi
		else
			if ! new_metadata_tsv="$(read_empty_metadata_stop_state_tsv "$old_user" "$old_version" "$old_identity")"; then
				printf '%s\n' "[systemd-user-manager] failed to prepare empty metadata for user: $old_user" >&2
				return 1
			fi
			if ! diff_and_stop_units apply "$old_user" "$state_metadata_tsv" "$new_metadata_tsv"; then
				return 1
			fi
		fi
	done
	run_metadata_pointer_stop_phase apply "$applied_users"
}

run_activation_dry_preview() {
	local preview_user preview_metadata preview_reconciler_service
	local preview_manifest_tsv=""

	require_env SYSTEMD_USER_MANAGER_OLD_SYSTEM
	require_env SYSTEMD_USER_MANAGER_NEW_SYSTEM
	require_env SYSTEMD_USER_MANAGER_PREVIEW_MANIFEST

	printf '%s\n' "[systemd-user-manager] dry-activate preview start"
	run_metadata_pointer_stop_phase preview
	if ! preview_manifest_tsv="$(jq -r '.[] | [.user, .metadataFile, .reconcilerService] | @tsv' "$systemd_user_manager_preview_manifest")"; then
		printf '%s\n' "[systemd-user-manager] failed to read preview manifest: $systemd_user_manager_preview_manifest" >&2
		exit 1
	fi
	if [ -n "$preview_manifest_tsv" ]; then
		while IFS=$'\t' read -r preview_user preview_metadata preview_reconciler_service; do
			run_preview_as_user "$preview_user" "$preview_metadata" "$preview_reconciler_service"
		done <<<"$preview_manifest_tsv"
	fi
	printf '%s\n' "[systemd-user-manager] dry-activate preview complete"
}

main() {
	local command
	command="${1-}"
	init_vars

	case "$command" in
	reconciler-apply)
		run_reconciler_apply
		;;
	dispatcher-start)
		run_dispatcher_start
		;;
	activation-stop-applied)
		run_activation_stop_applied
		;;
	activation-dry-preview)
		run_activation_dry_preview
		;;
	*)
		printf '%s\n' "usage: $0 {reconciler-apply|dispatcher-start|activation-stop-applied|activation-dry-preview}" >&2
		exit 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
