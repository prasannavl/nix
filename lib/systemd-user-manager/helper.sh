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
	deferred_unit_reload_request_dir="${SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RELOAD_REQUEST_DIR-}"
	migration_manager_gate_path="${SYSTEMD_USER_MANAGER_MIGRATION_MANAGER_GATE_PATH-}"
	metadata_field_sep=$'\037'
	metadata_field_sep_json='\u001f'
	stable_state_timeout_seconds="${SYSTEMD_USER_MANAGER_STABLE_STATE_TIMEOUT_SECONDS:-120}"
	start_materialize_seconds="${SYSTEMD_USER_MANAGER_START_MATERIALIZE_SECONDS:-10}"
	enqueue_start_grace_seconds="${SYSTEMD_USER_MANAGER_ENQUEUE_START_GRACE_SECONDS:-10}"
	stop_kill_wait_seconds="${SYSTEMD_USER_MANAGER_STOP_KILL_WAIT_SECONDS:-30}"
	start_concurrency="${SYSTEMD_USER_MANAGER_START_CONCURRENCY:-4}"
	verification_failed_units=""
	case "$start_concurrency" in
	-1) ;;
	"" | *[!0-9]* | 0) start_concurrency=4 ;;
	esac
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

migration_manager_gate_on() {
	[ -n "$migration_manager_gate_path" ] && [ -f "$migration_manager_gate_path" ]
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

ensure_user_owned_request_dir() {
	local user request_root request_dir user_gid
	user="$1"
	request_root="$2"
	request_dir="$3"
	user_gid="$(id -g "$user")"
	install -d -m 0711 "$request_root"
	chmod 0711 "$request_root"
	install -d -m 0750 "$request_dir"
	chown "$user:$user_gid" "$request_dir"
}

write_user_owned_request_file() {
	local user marker_path marker_value marker_tmp user_gid marker_dir
	user="$1"
	marker_path="$2"
	marker_value="$3"
	user_gid="$(id -g "$user")"
	marker_dir="$(dirname "$marker_path")"
	marker_tmp="${marker_dir}/.$(basename "$marker_path").tmp.$$"

	rm -f "$marker_tmp"
	printf '%s\n' "$marker_value" >"$marker_tmp"
	chown "$user:$user_gid" "$marker_tmp"
	chmod 0640 "$marker_tmp"
	mv -f "$marker_tmp" "$marker_path"
}

clear_user_owned_request_file() {
	local marker_path marker_dir
	marker_path="$1"
	marker_dir="$(dirname "$marker_path")"

	rm -f "$marker_path"
	rmdir "$marker_dir" 2>/dev/null || true
}

mark_deferred_managed_unit_restart() {
	local user managed_name marker_path marker_dir
	user="$1"
	managed_name="$2"
	require_env SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RESTART_REQUEST_DIR
	marker_path="$(managed_unit_restart_request_marker_path "$user" "$managed_name")"
	marker_dir="$(dirname "$marker_path")"
	ensure_user_owned_request_dir "$user" "$deferred_unit_restart_request_dir" "$marker_dir"
	write_user_owned_request_file "$user" "$marker_path" "$managed_name"
}

clear_deferred_managed_unit_restart() {
	local user managed_name marker_path
	user="$1"
	managed_name="$2"
	require_env SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RESTART_REQUEST_DIR
	marker_path="$(managed_unit_restart_request_marker_path "$user" "$managed_name")"
	clear_user_owned_request_file "$marker_path"
}

consume_deferred_managed_unit_restart() {
	local user managed_name marker_path marker_dir
	user="$1"
	managed_name="$2"
	require_env SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RESTART_REQUEST_DIR
	marker_path="$(managed_unit_restart_request_marker_path "$user" "$managed_name")"
	marker_dir="$(dirname "$marker_path")"
	if [ ! -f "$marker_path" ]; then
		printf '%s\n' "absent"
		return 0
	fi
	if ! rm -f "$marker_path"; then
		return 1
	fi
	rmdir "$marker_dir" 2>/dev/null || true
	printf '%s\n' "consumed"
}

managed_unit_reload_request_marker_path() {
	local user managed_name sanitized_user sanitized_name
	user="$1"
	managed_name="$2"
	sanitized_user="${user//\//-}"
	sanitized_name="${managed_name//\//-}"
	printf '%s/%s/%s' "$deferred_unit_reload_request_dir" "$sanitized_user" "$sanitized_name"
}

mark_deferred_managed_unit_reload() {
	local user managed_name reload_stamp marker_path marker_dir
	user="$1"
	managed_name="$2"
	reload_stamp="$3"
	require_env SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RELOAD_REQUEST_DIR
	marker_path="$(managed_unit_reload_request_marker_path "$user" "$managed_name")"
	marker_dir="$(dirname "$marker_path")"
	ensure_user_owned_request_dir "$user" "$deferred_unit_reload_request_dir" "$marker_dir"
	write_user_owned_request_file "$user" "$marker_path" "$reload_stamp"
}

clear_deferred_managed_unit_reload() {
	local user managed_name marker_path
	user="$1"
	managed_name="$2"
	require_env SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RELOAD_REQUEST_DIR
	marker_path="$(managed_unit_reload_request_marker_path "$user" "$managed_name")"
	clear_user_owned_request_file "$marker_path"
}

consume_deferred_managed_unit_reload() {
	local user managed_name expected_reload_stamp marker_path marker_dir marker_reload_stamp
	user="$1"
	managed_name="$2"
	expected_reload_stamp="$3"
	require_env SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RELOAD_REQUEST_DIR
	marker_path="$(managed_unit_reload_request_marker_path "$user" "$managed_name")"
	marker_dir="$(dirname "$marker_path")"
	if [ ! -f "$marker_path" ]; then
		printf '%s\n' "absent"
		return 0
	fi

	if ! IFS= read -r marker_reload_stamp <"$marker_path"; then
		return 1
	fi
	if ! rm -f "$marker_path"; then
		return 1
	fi
	rmdir "$marker_dir" 2>/dev/null || true
	if [ "$marker_reload_stamp" = "$expected_reload_stamp" ]; then
		printf '%s\n' "consumed"
	else
		printf '%s\n' "stale"
	fi
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

user_unit_progress_summary() {
	local unit active sub rest unit_result unit_restarts item summary="" count=0 max_units=8

	while read -r unit _load active sub rest; do
		[ -n "$unit" ] || continue
		case "$active:$sub" in
		activating:* | deactivating:* | failed:* | *:auto-restart | *:start | *:stop | *:stop-post) ;;
		*) continue ;;
		esac

		unit_result="$(userctl show --property=Result --value "$unit" 2>/dev/null || true)"
		unit_restarts="$(userctl show --property=NRestarts --value "$unit" 2>/dev/null || true)"
		item="${unit%.service}=${active}/${sub}"
		if [ -n "$unit_result" ] && [ "$unit_result" != success ]; then
			item="${item},result=${unit_result}"
		fi
		if [ -n "$unit_restarts" ] && [ "$unit_restarts" != 0 ]; then
			item="${item},restarts=${unit_restarts}"
		fi
		if [ -n "$summary" ]; then
			summary="${summary}; ${item}"
		else
			summary="$item"
		fi
		count=$((count + 1))
		if [ "$count" -ge "$max_units" ]; then
			break
		fi
	done < <(list_units_raw 2>/dev/null || true)

	if [ -n "$summary" ]; then
		printf '%s\n' "$summary"
	else
		printf '%s\n' "no pending/failed service units"
	fi
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

managed_unit_is_live_state() {
	case "$1" in
	active | activating | deactivating | reloading)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

managed_unit_is_restartable_state() {
	case "$1" in
	active | activating | deactivating | reloading | failed)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

managed_user_stop_state_unavailable() {
	local unit out
	unit="$1"

	if [ "$userctl_mode" != root ]; then
		return 1
	fi
	if ! systemctl is-active --quiet "user@${managed_user_uid}.service"; then
		return 0
	fi
	if [ ! -S "$managed_user_runtime_dir/bus" ]; then
		return 0
	fi

	if out="$(run_userctl_raw show --property=LoadState --value "$unit" 2>&1 >/dev/null)"; then
		return 1
	fi
	is_transient_userctl_error "$out"
}

mark_deferred_managed_unit_restart_if_restartable() {
	local user managed_name managed_unit active_state
	user="$1"
	managed_name="$2"
	managed_unit="$3"

	userctl_mode=root
	active_state="$(userctl_active_state "$managed_unit" 2>/dev/null || true)"
	if managed_unit_is_restartable_state "$active_state"; then
		mark_deferred_managed_unit_restart "$user" "$managed_name"
	fi
}

mark_deferred_managed_unit_reload_if_live() {
	local user managed_name managed_unit reload_stamp active_state
	user="$1"
	managed_name="$2"
	managed_unit="$3"
	reload_stamp="$4"

	userctl_mode=root
	active_state="$(userctl_active_state "$managed_unit" 2>/dev/null || true)"
	if managed_unit_is_live_state "$active_state"; then
		mark_deferred_managed_unit_reload "$user" "$managed_name" "$reload_stamp"
	fi
}

clear_deferred_managed_unit_requests() {
	local user managed_name
	user="$1"
	managed_name="$2"

	clear_deferred_managed_unit_restart "$user" "$managed_name"
	clear_deferred_managed_unit_reload "$user" "$managed_name"
}

stop_managed_unit() {
	local managed_unit load_state stop_error
	managed_unit="$1"
	if ! systemctl is-active --quiet "user@${managed_user_uid}.service"; then
		return 0
	fi
	if stop_error="$(userctl --no-block stop "$managed_unit" 2>&1 >/dev/null)"; then
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

reset_failed_managed_unit() {
	local managed_unit load_state reset_error
	managed_unit="$1"
	if [ "$userctl_mode" = root ] && ! systemctl is-active --quiet "user@${managed_user_uid}.service"; then
		return 0
	fi
	load_state="$(userctl_load_state "$managed_unit")"
	if [ "$load_state" = not-found ]; then
		return 0
	fi
	if reset_error="$(userctl reset-failed "$managed_unit" 2>&1 >/dev/null)"; then
		return 0
	fi
	reset_error="${reset_error:-systemctl returned an error}"
	printf '%s\n' "[systemd-user-manager] failed to reset failed state for $managed_unit: $reset_error" >&2
	return 1
}

kill_residual_managed_unit_processes() {
	local managed_unit signal load_state kill_error
	managed_unit="$1"
	signal="${2:-TERM}"
	if [ "$userctl_mode" = root ] && ! systemctl is-active --quiet "user@${managed_user_uid}.service"; then
		return 0
	fi
	load_state="$(userctl_load_state "$managed_unit")"
	if [ "$load_state" = not-found ]; then
		return 0
	fi
	if kill_error="$(userctl kill --kill-whom=all --signal="$signal" "$managed_unit" 2>&1 >/dev/null)"; then
		return 0
	fi
	if printf '%s' "$kill_error" | grep -Eq 'No such process|not loaded|not be found|not found|No matching processes'; then
		return 0
	fi
	kill_error="${kill_error:-systemctl returned an error}"
	printf '%s\n' "[systemd-user-manager] warning: failed to kill residual processes for $managed_unit: $kill_error" >&2
	return 0
}

wait_for_unit_stopped_state() {
	local unit timeout_seconds load_state active_state sub_state result started_at now elapsed_seconds sleep_seconds
	unit="$1"
	timeout_seconds="${2:-$stable_state_timeout_seconds}"
	started_at="$(now_epoch)"
	while true; do
		if managed_user_stop_state_unavailable "$unit"; then
			printf '%s\n' "user-manager-unavailable"
			return 0
		fi

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
	local phase_mode user managed_name managed_unit timeout_seconds reset_failed stopped_state managed_stopped_at stop_wait_timeout_seconds
	phase_mode="$1"
	user="$2"
	managed_name="$3"
	managed_unit="$4"
	timeout_seconds="${5:-$stable_state_timeout_seconds}"
	reset_failed="${6:-0}"

	if [ "$phase_mode" = preview ]; then
		log_managed_unit "$user" "$managed_name" "would stop"
		return 0
	fi

	if [ -z "$managed_user_name" ] || [ "$managed_user_name" != "$user" ]; then
		init_managed_user "$user"
	fi
	if [ "$(id -u)" = "$managed_user_uid" ]; then
		userctl_mode=user
	else
		userctl_mode=root
	fi
	log_managed_unit "$user" "$managed_name" "stopping"
	if ! stop_managed_unit "$managed_unit"; then
		return 1
	fi
	managed_stopped_at="$(now_epoch)"
	stop_wait_timeout_seconds="$timeout_seconds"
	if [ "$stop_wait_timeout_seconds" -gt "$stop_kill_wait_seconds" ]; then
		stop_wait_timeout_seconds="$stop_kill_wait_seconds"
	fi
	if managed_user_stop_state_unavailable "$managed_unit"; then
		log_managed_unit "$user" "$managed_name" "stopped in $(elapsed_since "$managed_stopped_at") (user-manager-unavailable)"
		return 0
	fi
	if ! stopped_state="$(wait_for_unit_stopped_state "$managed_unit" "$stop_wait_timeout_seconds")"; then
		log_managed_unit "$user" "$managed_name" "stop wait exceeded after $(elapsed_since "$managed_stopped_at"); killing residual processes"
		kill_residual_managed_unit_processes "$managed_unit" KILL
		if ! stopped_state="$(wait_for_unit_stopped_state "$managed_unit" "$stop_kill_wait_seconds")"; then
			log_managed_unit "$user" "$managed_name" "failed to stop after $(elapsed_since "$managed_stopped_at")"
			return 1
		fi
	fi
	kill_residual_managed_unit_processes "$managed_unit"
	if [ "$reset_failed" = 1 ] && ! reset_failed_managed_unit "$managed_unit"; then
		return 1
	fi
	log_managed_unit "$user" "$managed_name" "stopped in $(elapsed_since "$managed_stopped_at") ($stopped_state)"
}

queue_stop_phase_action() {
	if [ "${1-}" = preview ]; then
		apply_stop_phase_action "$@"
		return
	fi

	(
		apply_stop_phase_action "$@"
	) &
	stop_phase_action_pids+=("$!")
}

wait_for_stop_phase_actions() {
	local pid stop_failed=0

	for pid in "${stop_phase_action_pids[@]}"; do
		if ! wait "$pid"; then
			stop_failed=1
		fi
	done
	stop_phase_action_pids=()
	[ "$stop_failed" -eq 0 ]
}

encoded_command_args() {
	local command_b64
	command_b64="$1"
	[ -n "$command_b64" ] || return 0
	printf '%s' "$command_b64" | base64 -d | jq -r '.[]'
}

has_encoded_command() {
	local command_b64
	command_b64="$1"
	[ -n "$command_b64" ] || return 1
	printf '%s' "$command_b64" | base64 -d | jq -e 'length > 0' >/dev/null 2>&1
}

run_removal_command() {
	local command_b64
	local -a command=()
	command_b64="$1"
	mapfile -t command < <(encoded_command_args "$command_b64")
	[ "${#command[@]}" -gt 0 ] || return 1
	if [ "$userctl_mode" = root ]; then
		run_as_managed_user env PATH="$managed_user_action_path" "${command[@]}"
	else
		env PATH="$managed_user_action_path" "${command[@]}"
	fi
}

run_verify_command() {
	local command_b64
	local -a command=()
	command_b64="$1"
	mapfile -t command < <(encoded_command_args "$command_b64")
	[ "${#command[@]}" -gt 0 ] || return 0
	env PATH="$managed_user_action_path" "${command[@]}"
}

run_repair_command() {
	local command_b64
	local -a command=()
	command_b64="$1"
	mapfile -t command < <(encoded_command_args "$command_b64")
	[ "${#command[@]}" -gt 0 ] || return 1
	if [ "$userctl_mode" = root ]; then
		run_as_managed_user env PATH="$managed_user_action_path" "${command[@]}"
	else
		env PATH="$managed_user_action_path" "${command[@]}"
	fi
}

apply_removal_phase_action() {
	local phase_mode user managed_name managed_unit removal_policy removal_command_b64 timeout_seconds
	phase_mode="$1"
	user="$2"
	managed_name="$3"
	managed_unit="$4"
	removal_policy="$5"
	removal_command_b64="$6"
	timeout_seconds="${7:-$stable_state_timeout_seconds}"

	if [ "$removal_policy" = keep ]; then
		log_managed_unit "$user" "$managed_name" "removal kept for manual takeover"
		return 0
	fi

	if ! has_encoded_command "$removal_command_b64"; then
		apply_stop_phase_action "$phase_mode" "$user" "$managed_name" "$managed_unit" "$timeout_seconds"
		return $?
	fi

	if [ "$phase_mode" = preview ]; then
		log_managed_unit "$user" "$managed_name" "would run removal command"
		return 0
	fi

	userctl_mode=root
	log_managed_unit "$user" "$managed_name" "running removal command"
	if ! run_removal_command "$removal_command_b64"; then
		return 1
	fi
	log_managed_unit "$user" "$managed_name" "removal command finished"
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

metadata_jq_rows() {
	local row_filter="$1"
	shift || true

	jq -r "
		def usv: map(tostring) | join(\"${metadata_field_sep_json}\");
		(${row_filter}) | usv
	" "$@"
}

read_metadata_stop_state_tsv() {
	local metadata_file="$1"

	metadata_jq_rows '
		["metadata", (.version // 0), (.user // ""), (.identityStamp // "")],
		(.managedUnits[]? | [
			"unit",
			(.name // ""),
			(.unit // ""),
			(.removalPolicy // (if (.stopOnRemoval // true) then "stop" else "keep" end)),
			((.removalCommand // []) | @base64),
			(.stamp // ""),
			(.reloadStamp // ""),
			(if .autoStart then "1" else "0" end),
			(.state // "running"),
			(.timeoutReadySeconds // .timeoutStableSeconds // 120),
			(.transitionNeutralStamp // ""),
			(.stopOnTransitionFrom // ""),
			(.stopOnTransitionTo // "")
		])
	' "$metadata_file"
}

read_empty_metadata_stop_state_tsv() {
	local user version identity_stamp
	user="$1"
	version="$2"
	identity_stamp="$3"

	empty_metadata_for_user "$user" "$version" "$identity_stamp" | metadata_jq_rows '
		["metadata", (.version // 0), (.user // ""), (.identityStamp // "")]
	'
}

read_metadata_units_tsv() {
	local metadata_file="$1"

	metadata_jq_rows '
		.managedUnits[]?
		| [
			.name,
			.unit,
			(.removalPolicy // (if (.stopOnRemoval // true) then "stop" else "keep" end)),
			((.removalCommand // []) | @base64),
			(.stamp // ""),
			(if .autoStart then "1" else "0" end),
			(.state // "running"),
			(.timeoutReadySeconds // .timeoutStableSeconds // 120)
		]
	' "$metadata_file"
}

read_metadata_reconcile_units_tsv() {
	local metadata_file="$1"

	metadata_jq_rows '
		.managedUnits
		| sort_by(.name)[]
		| [
			.name,
			.unit,
			(if .autoStart then "1" else "0" end),
			(.state // "running"),
			(.timeoutReadySeconds // .timeoutStableSeconds // 120),
			(.reloadStamp // ""),
			(.startMode // "wait"),
			((.repairCommand // []) | @base64),
			((.verifyCommand // []) | @base64)
		]
	' "$metadata_file" |
		while IFS="$metadata_field_sep" read -r managed_name managed_unit auto_start desired_state timeout_seconds reload_stamp start_mode repair_command_b64 verify_command_b64; do
			if migration_manager_gate_on; then
				auto_start="0"
				desired_state="stopped"
			fi
			printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
				"$managed_name" "$metadata_field_sep" \
				"$managed_unit" "$metadata_field_sep" \
				"$auto_start" "$metadata_field_sep" \
				"$desired_state" "$metadata_field_sep" \
				"$timeout_seconds" "$metadata_field_sep" \
				"$reload_stamp" "$metadata_field_sep" \
				"$start_mode" "$metadata_field_sep" \
				"$repair_command_b64" "$metadata_field_sep" \
				"$verify_command_b64"
		done
}

metadata_header_from_stop_state_tsv() {
	local metadata_tsv record version user identity_stamp
	metadata_tsv="$1"

	while IFS="$metadata_field_sep" read -r record version user identity_stamp; do
		if [ "$record" = metadata ]; then
			printf '%s%s%s%s%s\n' "$version" "$metadata_field_sep" "$user" "$metadata_field_sep" "$identity_stamp"
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
	local stop_failed=0 new_name="" new_unit="" new_stamp="" new_reload_stamp="" new_auto_start="" new_state="" new_timeout="" new_transition_neutral_stamp="" new_stop_on_transition_to="" managed_name="" managed_unit="" removal_policy="" removal_command_b64="" old_stamp="" old_reload_stamp="" _old_auto_start="" _old_state="" managed_timeout="" old_transition_neutral_stamp="" old_stop_on_transition_from="" reset_failed=""
	local old_identity="" new_identity=""
	local record="" old_header="" new_header="" _old_version="" _old_user="" _new_version="" _new_user=""
	local changed_stop_timeout="" policy_only_change=0 transition_stop=0 stamp_changed=0 should_stop=0
	local new_metadata_present=0
	local -a stop_phase_action_pids=()
	local -A new_units_by_name=()
	local -A new_stamps_by_name=()
	local -A new_reload_stamps_by_name=()
	local -A new_auto_start_by_name=()
	local -A new_states_by_name=()
	local -A new_timeouts_by_name=()
	local -A new_transition_neutral_stamps_by_name=()
	local -A new_stop_on_transition_to_by_name=()
	local -A old_units_by_name=()

	phase_mode="$1"
	user="$2"
	old_metadata_tsv="$3"
	new_metadata_tsv="$4"

	if ! old_header="$(metadata_header_from_stop_state_tsv "$old_metadata_tsv")"; then
		printf '%s\n' "[systemd-user-manager] failed to read old metadata header for user: $user" >&2
		return 1
	fi
	IFS="$metadata_field_sep" read -r _old_version _old_user old_identity <<<"$old_header"
	if [ -n "$new_metadata_tsv" ]; then
		new_metadata_present=1
		if ! new_header="$(metadata_header_from_stop_state_tsv "$new_metadata_tsv")"; then
			printf '%s\n' "[systemd-user-manager] failed to read new metadata header for user: $user" >&2
			return 1
		fi
		IFS="$metadata_field_sep" read -r _new_version _new_user new_identity <<<"$new_header"
		while IFS="$metadata_field_sep" read -r record new_name new_unit _ _ new_stamp new_reload_stamp new_auto_start new_state new_timeout new_transition_neutral_stamp _new_stop_on_transition_from new_stop_on_transition_to; do
			[ "$record" = unit ] || continue
			[ -n "$new_name" ] || continue
			new_units_by_name["$new_name"]="$new_unit"
			new_stamps_by_name["$new_name"]="$new_stamp"
			new_reload_stamps_by_name["$new_name"]="$new_reload_stamp"
			new_auto_start_by_name["$new_name"]="$new_auto_start"
			new_states_by_name["$new_name"]="$new_state"
			new_timeouts_by_name["$new_name"]="$new_timeout"
			new_transition_neutral_stamps_by_name["$new_name"]="$new_transition_neutral_stamp"
			new_stop_on_transition_to_by_name["$new_name"]="$new_stop_on_transition_to"
		done <<<"$new_metadata_tsv"
	fi

	if [ -n "$old_metadata_tsv" ]; then
		while IFS="$metadata_field_sep" read -r record managed_name managed_unit removal_policy removal_command_b64 old_stamp old_reload_stamp _old_auto_start _old_state managed_timeout old_transition_neutral_stamp old_stop_on_transition_from _old_stop_on_transition_to; do
			[ "$record" = unit ] || continue
			old_units_by_name["$managed_name"]="$managed_unit"
			if [ "$phase_mode" = apply ]; then
				clear_deferred_managed_unit_requests "$user" "$managed_name"
			fi
			new_stamp="${new_stamps_by_name["$managed_name"]-}"
			new_reload_stamp="${new_reload_stamps_by_name["$managed_name"]-}"
			new_auto_start="${new_auto_start_by_name["$managed_name"]-1}"
			new_state="${new_states_by_name["$managed_name"]-running}"
			new_transition_neutral_stamp="${new_transition_neutral_stamps_by_name["$managed_name"]-}"
			new_stop_on_transition_to="${new_stop_on_transition_to_by_name["$managed_name"]-}"

			if [ -z "$new_stamp" ]; then
				if ! apply_removal_phase_action "$phase_mode" "$user" "$managed_name" "$managed_unit" "$removal_policy" "$removal_command_b64" "$managed_timeout"; then
					stop_failed=1
				fi
				continue
			fi

			stamp_changed=0
			should_stop=0
			policy_only_change=0
			transition_stop=0
			[ "$old_stamp" != "$new_stamp" ] && stamp_changed=1
			if [ -n "$old_transition_neutral_stamp" ] &&
				[ -n "$new_transition_neutral_stamp" ] &&
				[ "$old_transition_neutral_stamp" = "$new_transition_neutral_stamp" ]; then
				policy_only_change=1
				if [ -n "$old_stop_on_transition_from" ] &&
					[ "$old_stop_on_transition_from" = "$new_stop_on_transition_to" ]; then
					transition_stop=1
				fi
			fi
			if [ "$stamp_changed" -eq 1 ]; then
				if [ "$policy_only_change" -eq 1 ]; then
					:
				else
					should_stop=1
				fi
			fi
			if [ "$transition_stop" -eq 1 ]; then
				should_stop=1
			fi

			if [ "$should_stop" -eq 1 ]; then
				changed_stop_timeout="${new_timeouts_by_name["$managed_name"]-$managed_timeout}"
				if [ "$phase_mode" = apply ] && [ "$new_state" != "stopped" ]; then
					mark_deferred_managed_unit_restart_if_restartable "$user" "$managed_name" "$managed_unit"
				fi
				if [ "$new_state" = "stopped" ]; then
					reset_failed=1
				else
					reset_failed=0
				fi
				if ! queue_stop_phase_action "$phase_mode" "$user" "$managed_name" "$managed_unit" "$changed_stop_timeout" "$reset_failed"; then
					stop_failed=1
				fi
			elif [ -n "$new_reload_stamp" ] && [ "$old_reload_stamp" != "$new_reload_stamp" ]; then
				if [ "$new_state" = "stopped" ]; then
					if ! queue_stop_phase_action "$phase_mode" "$user" "$managed_name" "$managed_unit" "$managed_timeout" 1; then
						stop_failed=1
					fi
				elif [ "$phase_mode" = preview ]; then
					log_managed_unit "$user" "$managed_name" "would reload"
				else
					mark_deferred_managed_unit_reload_if_live "$user" "$managed_name" "$managed_unit" "$new_reload_stamp"
				fi
			fi
		done <<<"$old_metadata_tsv"
	fi

	if [ "$new_metadata_present" -eq 1 ]; then
		while IFS= read -r new_name; do
			[ -n "$new_name" ] || continue
			if [ -n "${old_units_by_name["$new_name"]+x}" ]; then
				continue
			fi
			new_auto_start="${new_auto_start_by_name["$new_name"]-1}"
			new_state="${new_states_by_name["$new_name"]-running}"
			if [ "$phase_mode" = preview ]; then
				[ "$new_auto_start" = 1 ] && [ "$new_state" != "stopped" ] && log_managed_unit "$user" "$new_name" "would start"
			elif [ "$new_auto_start" = 1 ] && [ "$new_state" != "stopped" ]; then
				mark_deferred_managed_unit_restart "$user" "$new_name"
			fi
		done < <(printf '%s\n' "${!new_units_by_name[@]}" | sort)
	fi

	if ! wait_for_stop_phase_actions; then
		stop_failed=1
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

stop_absent_units_after_metadata_version_change() {
	local phase_mode user old_metadata_tsv new_metadata_tsv
	local stop_failed=0 record="" managed_name="" managed_unit="" removal_policy="" removal_command_b64="" old_stamp="" old_reload_stamp="" _old_auto_start="" _old_state="" managed_timeout="" _old_transition_neutral_stamp="" _old_stop_on_transition_from="" _old_stop_on_transition_to=""
	local new_name=""
	local -A new_units_by_name=()

	phase_mode="$1"
	user="$2"
	old_metadata_tsv="$3"
	new_metadata_tsv="$4"

	if [ -n "$new_metadata_tsv" ]; then
		while IFS="$metadata_field_sep" read -r record new_name _; do
			[ "$record" = unit ] || continue
			[ -n "$new_name" ] || continue
			new_units_by_name["$new_name"]=1
		done <<<"$new_metadata_tsv"
	fi

	while IFS="$metadata_field_sep" read -r record managed_name managed_unit removal_policy removal_command_b64 old_stamp old_reload_stamp _old_auto_start _old_state managed_timeout _old_transition_neutral_stamp _old_stop_on_transition_from _old_stop_on_transition_to; do
		[ "$record" = unit ] || continue
		[ -n "$managed_name" ] || continue
		if [ "$phase_mode" = apply ]; then
			clear_deferred_managed_unit_requests "$user" "$managed_name"
		fi
		if [ -n "${new_units_by_name["$managed_name"]+x}" ]; then
			continue
		fi
		if ! apply_removal_phase_action "$phase_mode" "$user" "$managed_name" "$managed_unit" "$removal_policy" "$removal_command_b64" "$managed_timeout"; then
			stop_failed=1
		fi
	done <<<"$old_metadata_tsv"

	if [ "$phase_mode" = apply ] && [ "$stop_failed" -ne 0 ]; then
		return 1
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
	IFS="$metadata_field_sep" read -r old_version _ _ <<<"$state_header"
	if ! new_metadata_tsv="$(read_metadata_stop_state_tsv "$systemd_user_manager_metadata")"; then
		printf '%s\n' "[systemd-user-manager] failed to read managed units metadata: $systemd_user_manager_metadata" >&2
		return 1
	fi
	if ! new_header="$(metadata_header_from_stop_state_tsv "$new_metadata_tsv")"; then
		printf '%s\n' "[systemd-user-manager] failed to read metadata header: $systemd_user_manager_metadata" >&2
		return 1
	fi
	IFS="$metadata_field_sep" read -r new_version _ _ <<<"$new_header"
	if [ "$old_version" != "$new_version" ]; then
		log_user_progress "$systemd_user_manager_user" "applied metadata version changed; stopping removed units only"
		if ! stop_absent_units_after_metadata_version_change apply "$systemd_user_manager_user" "$state_metadata_tsv" "$new_metadata_tsv"; then
			return 1
		fi
		return
	fi
	diff_and_stop_units apply "$systemd_user_manager_user" "$state_metadata_tsv" "$new_metadata_tsv"
}

stop_active_managed_units_without_applied_metadata() {
	local managed_units_tsv="" managed_name="" managed_unit="" _removal_policy="" _removal_command_b64="" auto_start="" desired_state="" managed_timeout="" active_state="" stop_failed=0 reset_failed=0
	local -a stop_phase_action_pids=()
	require_env SYSTEMD_USER_MANAGER_METADATA
	if ! managed_units_tsv="$(read_metadata_units_tsv "$systemd_user_manager_metadata")"; then
		printf '%s\n' "[systemd-user-manager] failed to read managed units metadata: $systemd_user_manager_metadata" >&2
		return 1
	fi
	[ -n "$managed_units_tsv" ] || return 0
	while IFS="$metadata_field_sep" read -r managed_name managed_unit _removal_policy _removal_command_b64 _ auto_start desired_state managed_timeout; do
		[ -n "$managed_name" ] || continue
		clear_deferred_managed_unit_requests "$systemd_user_manager_user" "$managed_name"
		active_state="$(userctl_active_state "$managed_unit" 2>/dev/null || true)"
		case "$active_state" in
		active | activating | deactivating | reloading) ;;
		*)
			continue
			;;
		esac
		if [ "$desired_state" != "stopped" ]; then
			mark_deferred_managed_unit_restart_if_restartable "$systemd_user_manager_user" "$managed_name" "$managed_unit"
		fi
		if [ "$desired_state" = "stopped" ]; then
			reset_failed=1
		else
			reset_failed=0
		fi
		if ! queue_stop_phase_action apply "$systemd_user_manager_user" "$managed_name" "$managed_unit" "$managed_timeout" "$reset_failed"; then
			stop_failed=1
		fi
	done <<<"$managed_units_tsv"
	if ! wait_for_stop_phase_actions; then
		stop_failed=1
	fi
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
	local unit timeout_seconds active_state sub_state result initial_restarts current_restarts last_reported_restarts started_at now elapsed_seconds sleep_seconds
	unit="$1"
	timeout_seconds="${2:-$stable_state_timeout_seconds}"
	initial_restarts="$(userctl show --property=NRestarts --value "$unit" 2>/dev/null || true)"
	case "$initial_restarts" in
	'' | *[!0-9]*) initial_restarts=0 ;;
	esac
	last_reported_restarts="$initial_restarts"
	started_at="$(now_epoch)"
	while true; do
		active_state="$(userctl show --property=ActiveState --value "$unit")"
		sub_state="$(userctl show --property=SubState --value "$unit")"
		result="$(userctl show --property=Result --value "$unit")"
		current_restarts="$(userctl show --property=NRestarts --value "$unit" 2>/dev/null || true)"
		case "$current_restarts" in
		'' | *[!0-9]*) current_restarts=0 ;;
		esac
		case "$active_state" in
		activating | deactivating | reloading)
			now="$(now_epoch)"
			elapsed_seconds="$((now - started_at))"
			if [ "$current_restarts" -gt "$last_reported_restarts" ]; then
				log_progress "unit $unit restarted while converging: active=$active_state sub=$sub_state result=$result restarts=${current_restarts} initial_restarts=${initial_restarts}"
				last_reported_restarts="$current_restarts"
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

unit_started_state() {
	local unit timeout_seconds active_state sub_state result service_type job initial_restarts current_restarts last_reported_restarts started_at now elapsed_seconds sleep_seconds
	unit="$1"
	timeout_seconds="${2:-$stable_state_timeout_seconds}"
	initial_restarts="$(userctl show --property=NRestarts --value "$unit" 2>/dev/null || true)"
	case "$initial_restarts" in
	'' | *[!0-9]*) initial_restarts=0 ;;
	esac
	last_reported_restarts="$initial_restarts"
	started_at="$(now_epoch)"
	while true; do
		active_state="$(userctl show --property=ActiveState --value "$unit")"
		sub_state="$(userctl show --property=SubState --value "$unit")"
		result="$(userctl show --property=Result --value "$unit")"
		current_restarts="$(userctl show --property=NRestarts --value "$unit" 2>/dev/null || true)"
		case "$current_restarts" in
		'' | *[!0-9]*) current_restarts=0 ;;
		esac
		now="$(now_epoch)"
		elapsed_seconds="$((now - started_at))"
		case "$active_state" in
		active | failed)
			if [ "$elapsed_seconds" -gt 0 ]; then
				log_progress "stable state reached: unit=$unit state=$active_state sub=$sub_state"
			fi
			printf '%s\n' "$active_state"
			return 0
			;;
		inactive)
			service_type="$(userctl show --property=Type --value "$unit" 2>/dev/null || true)"
			if [ "$result" = success ] && [ "$service_type" = oneshot ]; then
				if [ "$elapsed_seconds" -gt 0 ]; then
					log_progress "successful oneshot completion reached: unit=$unit state=$active_state sub=$sub_state"
				fi
				printf '%s\n' "$active_state"
				return 0
			fi
			job="$(userctl show --property=Job --value "$unit" 2>/dev/null || true)"
			if [ -n "$job" ] && [ "$job" != 0 ]; then
				if [ "$elapsed_seconds" -eq 0 ]; then
					log_progress "waiting for start job: unit=$unit job=$job current=$active_state sub=$sub_state"
				fi
				if [ "$elapsed_seconds" -ge "$timeout_seconds" ]; then
					printf '%s\n' "timed out waiting ${timeout_seconds}s for start job for $unit (active=$active_state sub=$sub_state result=$result job=$job)" >&2
					return 1
				fi
				sleep_seconds="$(stable_state_backoff_seconds "$elapsed_seconds")"
				sleep "$sleep_seconds"
				continue
			fi
			if [ "$elapsed_seconds" -lt "$start_materialize_seconds" ]; then
				if [ "$elapsed_seconds" -eq 0 ]; then
					log_progress "waiting for start transaction: unit=$unit current=$active_state sub=$sub_state"
				fi
				sleep_seconds="$(stable_state_backoff_seconds "$elapsed_seconds")"
				sleep "$sleep_seconds"
				continue
			fi
			log_progress "stable state reached: unit=$unit state=$active_state sub=$sub_state"
			printf '%s\n' "$active_state"
			return 0
			;;
		activating | deactivating | reloading)
			if [ "$current_restarts" -gt "$last_reported_restarts" ]; then
				log_progress "unit $unit restarted while converging: active=$active_state sub=$sub_state result=$result restarts=${current_restarts} initial_restarts=${initial_restarts}"
				last_reported_restarts="$current_restarts"
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
			if [ "$elapsed_seconds" -gt 0 ]; then
				log_progress "stable state reached: unit=$unit state=$active_state sub=$sub_state"
			fi
			printf '%s\n' "$active_state"
			return 0
			;;
		esac
	done
}

unit_enqueued_start_state() {
	local unit grace_seconds active_state sub_state result service_type started_at now elapsed_seconds sleep_seconds
	unit="$1"
	grace_seconds="${2:-$enqueue_start_grace_seconds}"
	started_at="$(now_epoch)"

	while true; do
		active_state="$(userctl show --property=ActiveState --value "$unit" 2>/dev/null || true)"
		sub_state="$(userctl show --property=SubState --value "$unit" 2>/dev/null || true)"
		result="$(userctl show --property=Result --value "$unit" 2>/dev/null || true)"
		service_type="$(userctl show --property=Type --value "$unit" 2>/dev/null || true)"
		now="$(now_epoch)"
		elapsed_seconds="$((now - started_at))"

		case "$active_state" in
		active)
			printf '%s\n' "$active_state"
			return 0
			;;
		inactive)
			if [ "$result" = success ] && [ "$service_type" = oneshot ]; then
				printf '%s\n' "$active_state"
				return 0
			fi
			if [ "$result" = failed ]; then
				printf '%s\n' "unit $unit failed during enqueue start (active=$active_state sub=$sub_state result=$result)" >&2
				return 1
			fi
			;;
		failed)
			printf '%s\n' "unit $unit failed during enqueue start (active=$active_state sub=$sub_state result=$result)" >&2
			return 1
			;;
		activating | deactivating | reloading)
			if [ "$elapsed_seconds" -ge "$grace_seconds" ]; then
				log_progress "enqueue accepted: unit=$unit state=$active_state sub=$sub_state"
				printf '%s\n' "$active_state"
				return 0
			fi
			sleep_seconds="$(stable_state_backoff_seconds "$elapsed_seconds")"
			sleep "$sleep_seconds"
			continue
			;;
		esac

		if [ "$elapsed_seconds" -ge "$grace_seconds" ]; then
			printf '%s\n' "unit $unit did not enter an enqueued start state after ${grace_seconds}s (active=$active_state sub=$sub_state result=$result)" >&2
			return 1
		fi
		sleep_seconds="$(stable_state_backoff_seconds "$elapsed_seconds")"
		sleep "$sleep_seconds"
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

emit_managed_unit_failure_diagnostics() {
	local unit property value invocation_id details=""
	local -a journal_args
	unit="$1"

	for property in ActiveState SubState Result ExecMainCode ExecMainStatus; do
		value="$(userctl show --property="$property" --value "$unit" 2>/dev/null || true)"
		[ -n "$value" ] || value="unknown"
		details="${details} ${property}=${value}"
	done
	printf '%s\n' "[systemd-user-manager] managed unit failure: unit=$unit${details}" >&2

	invocation_id="$(userctl show --property=InvocationID --value "$unit" 2>/dev/null || true)"
	journal_args=(-n 20 --no-pager -o cat)
	if [ -n "$invocation_id" ]; then
		journal_args+=("_SYSTEMD_INVOCATION_ID=$invocation_id")
	else
		journal_args+=("--user-unit=$unit")
	fi
	printf '%s\n' "[systemd-user-manager] recent journal for $unit:" >&2
	if [ "$userctl_mode" = root ]; then
		run_as_managed_user timeout 2s journalctl --user "${journal_args[@]}" >&2 || true
	else
		timeout 2s journalctl --user "${journal_args[@]}" >&2 || true
	fi
}

emit_failed_managed_unit_diagnostics() {
	local failed_units_in managed_units_tsv failed_name
	local managed_name="" managed_unit="" _rest=""
	failed_units_in="$1"
	managed_units_tsv="$2"

	for failed_name in $failed_units_in; do
		while IFS="$metadata_field_sep" read -r managed_name managed_unit _rest; do
			[ "$managed_name" = "$failed_name" ] || continue
			emit_managed_unit_failure_diagnostics "$managed_unit"
			break
		done <<<"$managed_units_tsv"
	done
}

launch_managed_unit_action() {
	local managed_name managed_unit action managed_started_at timeout_seconds start_mode active_state result service_type userctl_status
	managed_name="$1"
	managed_unit="$2"
	action="$3"
	managed_started_at="$4"
	timeout_seconds="${5:-$stable_state_timeout_seconds}"
	start_mode="${6:-wait}"
	managed_unit_outcome="$action"

	if [ "$dry_run" = 1 ]; then
		log_managed_unit "$systemd_user_manager_user" "$managed_name" "would $action"
	else
		if [ "$action" = start ]; then
			kill_residual_managed_unit_processes "$managed_unit"
		fi
		if ! reset_failed_managed_unit "$managed_unit"; then
			managed_unit_outcome="fail"
			return 1
		fi
		log_managed_unit "$systemd_user_manager_user" "$managed_name" "${action}ing"
		(
			userctl_status=0
			userctl --no-block "$action" "$managed_unit" || userctl_status=$?
			if [ "$userctl_status" -ne 0 ] && [ "$action" != start ]; then
				if [ "$start_mode" != enqueue ]; then
					printf '%s\n' "userctl $action $managed_unit failed before stable wait: status=$userctl_status" >&2
					exit 1
				fi
			fi
			if [ "$start_mode" = enqueue ] && { [ "$action" = start ] || [ "$action" = restart ]; }; then
				if ! active_state="$(unit_enqueued_start_state "$managed_unit")"; then
					if [ "$userctl_status" -ne 0 ]; then
						printf '%s\n' "userctl $action $managed_unit returned status=$userctl_status and enqueue wait failed" >&2
					fi
					exit 1
				fi
				case "$active_state" in
				active | inactive | activating | deactivating | reloading)
					if [ "$userctl_status" -ne 0 ]; then
						printf '%s\n' "userctl $action $managed_unit returned status=$userctl_status, accepting enqueued state $active_state" >&2
					fi
					exit 0
					;;
				esac
				printf '%s\n' "unit $managed_unit reached unexpected state after enqueue $action: $active_state" >&2
				exit 1
			elif ! active_state="$(unit_started_state "$managed_unit" "$timeout_seconds")"; then
				if [ "$userctl_status" -ne 0 ]; then
					printf '%s\n' "userctl $action $managed_unit returned status=$userctl_status and stable wait failed" >&2
				fi
				exit 1
			fi
			case "$active_state" in
			active)
				if [ "$userctl_status" -ne 0 ]; then
					printf '%s\n' "userctl $action $managed_unit returned status=$userctl_status, accepting final active state" >&2
				fi
				exit 0
				;;
			inactive)
				result="$(userctl show --property=Result --value "$managed_unit" 2>/dev/null || true)"
				service_type="$(userctl show --property=Type --value "$managed_unit" 2>/dev/null || true)"
				if [ "$result" = success ] && [ "$service_type" = oneshot ]; then
					if [ "$userctl_status" -ne 0 ]; then
						printf '%s\n' "userctl $action $managed_unit returned status=$userctl_status, accepting final successful oneshot state" >&2
					fi
					exit 0
				fi
				;;
			esac
			printf '%s\n' "unit $managed_unit reached stable non-active state after $action: $active_state" >&2
			exit 1
		) &
		managed_unit_action_pid=$!
		managed_unit_action_started_at="$managed_started_at"
	fi
}

managed_unit_action_past_tense() {
	case "$1" in
	start)
		printf '%s\n' "started"
		;;
	restart)
		printf '%s\n' "restarted"
		;;
	*)
		printf '%s\n' "$1"
		;;
	esac
}

wait_for_managed_action_index() {
	local action_index managed_name managed_action managed_started_at
	action_index="$1"
	managed_name="${managed_action_names[$action_index]}"
	managed_action="${managed_action_actions[$action_index]}"
	managed_started_at="${managed_action_started_ats[$action_index]}"
	if wait "${managed_action_pids[$action_index]}"; then
		log_managed_unit "$systemd_user_manager_user" "$managed_name" "$(managed_unit_action_past_tense "$managed_action") in $(elapsed_since "$managed_started_at")"
	else
		log_managed_unit "$systemd_user_manager_user" "$managed_name" "failed to ${managed_action} after $(elapsed_since "$managed_started_at")"
		failed_units="${failed_units} ${managed_name}"
	fi
}

managed_unit_matches_desired_state() {
	local managed_unit auto_start desired_state timeout_seconds active_state service_type result
	managed_unit="$1"
	auto_start="$2"
	desired_state="$3"
	timeout_seconds="${4:-$stable_state_timeout_seconds}"

	if ! active_state="$(unit_stable_state "$managed_unit" "$timeout_seconds" 2>/dev/null)"; then
		return 1
	fi

	if [ "$desired_state" = "stopped" ]; then
		case "$active_state" in
		inactive | failed)
			return 0
			;;
		esac
		return 1
	fi

	case "$active_state" in
	active)
		return 0
		;;
	inactive)
		service_type="$(userctl show --property=Type --value "$managed_unit" 2>/dev/null || true)"
		result="$(userctl show --property=Result --value "$managed_unit" 2>/dev/null || true)"
		if [ "$service_type" = oneshot ] && [ "$result" = success ]; then
			return 0
		fi
		;;
	esac

	[ "$auto_start" != 1 ] && return 0
	return 1
}

prune_converged_failed_units() {
	local failed_units_in managed_units_tsv remaining_failed_units failed_name
	local managed_name="" managed_unit="" auto_start="" desired_state="" managed_timeout="" _rest=""
	failed_units_in="$1"
	managed_units_tsv="$2"
	remaining_failed_units=""

	for failed_name in $failed_units_in; do
		local found=0 recovered=0
		while IFS="$metadata_field_sep" read -r managed_name managed_unit auto_start desired_state managed_timeout _rest; do
			[ -n "$managed_name" ] || continue
			if [ "$managed_name" != "$failed_name" ]; then
				continue
			fi
			found=1
			# The action already consumed its full convergence budget. Only accept
			# recovery that is visible now; do not make deployment wait twice.
			if managed_unit_matches_desired_state "$managed_unit" "$auto_start" "$desired_state" 0; then
				recovered=1
				log_managed_unit "$systemd_user_manager_user" "$managed_name" "recovered after delayed convergence"
			fi
			break
		done <<<"$managed_units_tsv"
		if [ "$found" -eq 0 ] || [ "$recovered" -eq 0 ]; then
			case " $remaining_failed_units " in
			*" $failed_name "*) ;;
			*) remaining_failed_units="${remaining_failed_units} ${failed_name}" ;;
			esac
		fi
	done

	printf '%s\n' "$remaining_failed_units"
}

recover_transitional_managed_unit() {
	local managed_name managed_unit active_state timeout_seconds managed_started_at start_mode reset_failed
	managed_name="$1"
	managed_unit="$2"
	active_state="$3"
	timeout_seconds="${4:-$stable_state_timeout_seconds}"
	managed_started_at="$5"
	start_mode="${6:-wait}"

	log_managed_unit "$systemd_user_manager_user" "$managed_name" "recovering transitional state (state=$active_state)"
	reset_failed=0
	if [ "$start_mode" = enqueue ]; then
		if [ "$dry_run" = 1 ]; then
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "would enqueue recovery start"
			managed_unit_outcome="start"
			return 0
		fi
		kill_residual_managed_unit_processes "$managed_unit" KILL
		if ! launch_managed_unit_action "$managed_name" "$managed_unit" start "$managed_started_at" "$timeout_seconds" "$start_mode"; then
			return 1
		fi
		return 0
	fi
	if [ "$dry_run" = 1 ]; then
		apply_stop_phase_action preview "$systemd_user_manager_user" "$managed_name" "$managed_unit" "$timeout_seconds" "$reset_failed"
	elif ! apply_stop_phase_action apply "$systemd_user_manager_user" "$managed_name" "$managed_unit" "$timeout_seconds" "$reset_failed"; then
		managed_unit_outcome="fail"
		return 1
	fi
	if ! launch_managed_unit_action "$managed_name" "$managed_unit" start "$managed_started_at" "$timeout_seconds" "$start_mode"; then
		return 1
	fi
}

start_managed_unit() {
	local managed_name managed_unit auto_start desired_state timeout_seconds start_mode repair_command_b64 active_state unit_file_state managed_started_at restart_marker_state verify_command_b64
	managed_name="$1"
	managed_unit="$2"
	auto_start="$3"
	desired_state="$4"
	timeout_seconds="${5:-$stable_state_timeout_seconds}"
	start_mode="${6:-wait}"
	repair_command_b64="${7:-}"
	verify_command_b64="${8:-}"
	managed_unit_outcome="noop"
	managed_unit_action_pid=""
	managed_unit_action_started_at=""
	managed_started_at="$(now_epoch)"

	active_state="$(userctl_active_state "$managed_unit" 2>/dev/null || true)"

	if [ "$desired_state" = "stopped" ]; then
		case "$active_state" in
		inactive | failed | "")
			if [ "$dry_run" != 1 ] && ! reset_failed_managed_unit "$managed_unit"; then
				managed_unit_outcome="fail"
				return 1
			fi
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "skipped (state=stopped)"
			managed_unit_outcome="skip"
			return 0
			;;
		*)
			managed_unit_outcome="skip"
			if [ "$dry_run" = 1 ]; then
				apply_stop_phase_action preview "$systemd_user_manager_user" "$managed_name" "$managed_unit" "$timeout_seconds" 1
			elif ! apply_stop_phase_action apply "$systemd_user_manager_user" "$managed_name" "$managed_unit" "$timeout_seconds" 1; then
				managed_unit_outcome="fail"
				return 1
			fi
			return 0
			;;
		esac
	fi

	if ! restart_marker_state="$(consume_deferred_managed_unit_restart "$systemd_user_manager_user" "$managed_name")"; then
		managed_unit_outcome="fail"
		return 1
	fi

	if [ "$restart_marker_state" = consumed ]; then
		case "$active_state" in
		active)
			if [ "$start_mode" = enqueue ] && has_encoded_command "$repair_command_b64"; then
				if [ "$dry_run" = 1 ]; then
					log_managed_unit "$systemd_user_manager_user" "$managed_name" "would enqueue repair"
					managed_unit_outcome="restart"
					return 0
				fi
				log_managed_unit "$systemd_user_manager_user" "$managed_name" "enqueueing repair"
				if run_repair_command "$repair_command_b64"; then
					log_managed_unit "$systemd_user_manager_user" "$managed_name" "repair enqueued"
					managed_unit_outcome="restart"
					return 0
				fi
				log_managed_unit "$systemd_user_manager_user" "$managed_name" "failed to enqueue repair"
				managed_unit_outcome="fail"
				return 1
			fi
			if ! launch_managed_unit_action "$managed_name" "$managed_unit" restart "$managed_started_at" "$timeout_seconds" "$start_mode"; then
				return 1
			fi
			return 0
			;;
		activating | deactivating | reloading)
			recover_transitional_managed_unit "$managed_name" "$managed_unit" "$active_state" "$timeout_seconds" "$managed_started_at" "$start_mode"
			return $?
			;;
		inactive | failed)
			if ! launch_managed_unit_action "$managed_name" "$managed_unit" start "$managed_started_at" "$timeout_seconds" "$start_mode"; then
				return 1
			fi
			return 0
			;;
		*)
			printf '%s\n' "unexpected stable ActiveState for $managed_unit: $active_state" >&2
			return 1
			;;
		esac
	fi

	case "$active_state" in
	inactive | failed | "")
		unit_file_state="$(userctl_unit_file_state "$managed_unit")"
		case "$unit_file_state" in
		disabled | masked | masked-runtime)
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "skipped ($unit_file_state)"
			managed_unit_outcome="skip"
			return 0
			;;
		esac
		if [ "$auto_start" != 1 ]; then
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "skipped (autoStart=false)"
		else
			if ! launch_managed_unit_action "$managed_name" "$managed_unit" start "$managed_started_at" "$timeout_seconds" "$start_mode"; then
				return 1
			fi
			return 0
		fi
		managed_unit_outcome="skip"
		return 0
		;;
	active)
		return 0
		;;
	activating)
		if [ "$auto_start" != 1 ]; then
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "skipped (autoStart=false state=$active_state)"
			managed_unit_outcome="skip"
			return 0
		fi
		if ! launch_managed_unit_action "$managed_name" "$managed_unit" start "$managed_started_at" "$timeout_seconds" "$start_mode"; then
			return 1
		fi
		return 0
		;;
	deactivating | reloading)
		if [ "$auto_start" != 1 ]; then
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "skipped (autoStart=false state=$active_state)"
			managed_unit_outcome="skip"
			return 0
		fi
		recover_transitional_managed_unit "$managed_name" "$managed_unit" "$active_state" "$timeout_seconds" "$managed_started_at" "$start_mode"
		return $?
		;;
	*)
		log_managed_unit "$systemd_user_manager_user" "$managed_name" "skipped (state=$active_state)"
		managed_unit_outcome="skip"
		return 0
		;;
	esac
}

reload_managed_unit() {
	local managed_name managed_unit timeout_seconds active_state managed_reloaded_at
	managed_name="$1"
	managed_unit="$2"
	timeout_seconds="${3:-$stable_state_timeout_seconds}"
	managed_reloaded_at="$(now_epoch)"

	if ! active_state="$(unit_stable_state "$managed_unit" "$timeout_seconds")"; then
		log_managed_unit "$systemd_user_manager_user" "$managed_name" "failed before reload after $(elapsed_since "$managed_reloaded_at")"
		return 1
	fi

	if [ "$active_state" != active ]; then
		log_managed_unit "$systemd_user_manager_user" "$managed_name" "reload skipped ($active_state)"
		return 0
	fi

	log_managed_unit "$systemd_user_manager_user" "$managed_name" "reloading"
	if ! userctl reload "$managed_unit"; then
		log_managed_unit "$systemd_user_manager_user" "$managed_name" "failed to reload after $(elapsed_since "$managed_reloaded_at")"
		return 1
	fi

	if ! unit_stable_state "$managed_unit" "$timeout_seconds" >/dev/null; then
		log_managed_unit "$systemd_user_manager_user" "$managed_name" "failed after reload after $(elapsed_since "$managed_reloaded_at")"
		return 1
	fi

	log_managed_unit "$systemd_user_manager_user" "$managed_name" "reloaded in $(elapsed_since "$managed_reloaded_at")"
}

reload_changed_managed_units_from_metadata() {
	local managed_units_tsv="" managed_name="" managed_unit="" _auto_start="" _desired_state="" managed_timeout="" managed_reload_stamp="" _start_mode="" _repair_command_b64="" _verify_command_b64="" failed_units="" reload_marker_state=""
	require_env SYSTEMD_USER_MANAGER_METADATA
	if ! managed_units_tsv="$(read_metadata_reconcile_units_tsv "$systemd_user_manager_metadata")"; then
		printf '%s\n' "[systemd-user-manager] failed to read managed units metadata: $systemd_user_manager_metadata" >&2
		return 1
	fi
	[ -n "$managed_units_tsv" ] || return 0
	while IFS="$metadata_field_sep" read -r managed_name managed_unit _auto_start _desired_state managed_timeout managed_reload_stamp _start_mode _repair_command_b64 _verify_command_b64; do
		[ -n "$managed_name" ] || continue
		if ! reload_marker_state="$(consume_deferred_managed_unit_reload "$systemd_user_manager_user" "$managed_name" "$managed_reload_stamp")"; then
			failed_units="${failed_units} ${managed_name}"
			continue
		fi
		if [ "$reload_marker_state" != consumed ]; then
			continue
		fi
		if ! reload_managed_unit "$managed_name" "$managed_unit" "$managed_timeout"; then
			failed_units="${failed_units} ${managed_name}"
		fi
	done <<<"$managed_units_tsv"
	if [ -n "$failed_units" ]; then
		printf '%s\n' "failed managed unit reloads:$failed_units" >&2
		return 1
	fi
}

enqueue_repair_after_verification_failure() {
	local managed_name managed_unit managed_timeout start_mode repair_command_b64 state_context managed_verified_at
	managed_name="$1"
	managed_unit="$2"
	managed_timeout="$3"
	start_mode="$4"
	repair_command_b64="$5"
	state_context="${6:-}"
	managed_verified_at="$(now_epoch)"

	if has_encoded_command "$repair_command_b64"; then
		log_managed_unit "$systemd_user_manager_user" "$managed_name" "verification failed${state_context}; enqueueing repair"
		if run_repair_command "$repair_command_b64"; then
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "repair enqueued after verification failure in $(elapsed_since "$managed_verified_at")"
			return 0
		fi
		log_managed_unit "$systemd_user_manager_user" "$managed_name" "failed to enqueue repair after verification failure"
		return 1
	fi

	log_managed_unit "$systemd_user_manager_user" "$managed_name" "verification failed${state_context}; enqueueing restart"
	if launch_managed_unit_action "$managed_name" "$managed_unit" restart "$managed_verified_at" "$managed_timeout" "$start_mode" &&
		wait "$managed_unit_action_pid"; then
		log_managed_unit "$systemd_user_manager_user" "$managed_name" "restart enqueued after verification failure in $(elapsed_since "$managed_verified_at")"
		return 0
	fi
	log_managed_unit "$systemd_user_manager_user" "$managed_name" "failed to enqueue restart after verification failure"
	return 1
}

verify_managed_units_from_metadata() {
	local skip_units="${1:-}"
	local managed_units_tsv="" managed_name="" managed_unit="" _auto_start="" desired_state="" managed_timeout="" _reload_stamp="" start_mode="" repair_command_b64="" verify_command_b64="" active_state="" failed_units="" managed_verified_at="" managed_unit_outcome="" managed_unit_action_pid="" managed_unit_action_started_at=""
	verification_failed_units=""
	require_env SYSTEMD_USER_MANAGER_METADATA
	if ! managed_units_tsv="$(read_metadata_reconcile_units_tsv "$systemd_user_manager_metadata")"; then
		printf '%s\n' "[systemd-user-manager] failed to read managed units metadata: $systemd_user_manager_metadata" >&2
		return 1
	fi
	[ -n "$managed_units_tsv" ] || return 0
	while IFS="$metadata_field_sep" read -r managed_name managed_unit _auto_start desired_state managed_timeout _reload_stamp start_mode repair_command_b64 verify_command_b64; do
		[ -n "$managed_name" ] || continue
		start_mode="${start_mode:-wait}"
		case " $skip_units " in
		*" $managed_name "*) continue ;;
		esac
		[ "$desired_state" = "running" ] || continue
		if ! has_encoded_command "$verify_command_b64"; then
			continue
		fi
		if [ "$start_mode" = enqueue ]; then
			active_state="$(userctl_active_state "$managed_unit" 2>/dev/null || true)"
		elif ! active_state="$(unit_stable_state "$managed_unit" "$managed_timeout")"; then
			failed_units="${failed_units} ${managed_name}"
			continue
		fi
		if [ "$start_mode" = enqueue ]; then
			case "$active_state" in
			activating | deactivating | reloading)
				if run_verify_command "$verify_command_b64"; then
					log_managed_unit "$systemd_user_manager_user" "$managed_name" "verification deferred (state=$active_state)"
					continue
				fi
				;;
			esac
		fi
		if [ "$active_state" != active ]; then
			if [ "$_auto_start" != 1 ]; then
				log_managed_unit "$systemd_user_manager_user" "$managed_name" "verification skipped (autoStart=false state=$active_state)"
				continue
			fi
			if [ "$start_mode" = enqueue ]; then
				if enqueue_repair_after_verification_failure "$managed_name" "$managed_unit" "$managed_timeout" "$start_mode" "$repair_command_b64" " (state=$active_state)"; then
					continue
				fi
				failed_units="${failed_units} ${managed_name}"
				continue
			fi
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "verification failed (state=$active_state)"
			failed_units="${failed_units} ${managed_name}"
			continue
		fi
		if ! run_verify_command "$verify_command_b64"; then
			managed_verified_at="$(now_epoch)"
			if [ "$start_mode" = enqueue ]; then
				if enqueue_repair_after_verification_failure "$managed_name" "$managed_unit" "$managed_timeout" "$start_mode" "$repair_command_b64"; then
					continue
				fi
				failed_units="${failed_units} ${managed_name}"
				continue
			fi
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "verification failed; restarting"
			if ! launch_managed_unit_action "$managed_name" "$managed_unit" restart "$managed_verified_at" "$managed_timeout" "$start_mode"; then
				log_managed_unit "$systemd_user_manager_user" "$managed_name" "failed to restart after verification failure"
				failed_units="${failed_units} ${managed_name}"
				continue
			fi
			if ! wait "$managed_unit_action_pid"; then
				log_managed_unit "$systemd_user_manager_user" "$managed_name" "failed after restart from verification failure"
				failed_units="${failed_units} ${managed_name}"
				continue
			fi
			if ! active_state="$(unit_stable_state "$managed_unit" "$managed_timeout")" || [ "$active_state" != active ]; then
				log_managed_unit "$systemd_user_manager_user" "$managed_name" "failed after restart from verification failure"
				failed_units="${failed_units} ${managed_name}"
				continue
			fi
			if ! run_verify_command "$verify_command_b64"; then
				log_managed_unit "$systemd_user_manager_user" "$managed_name" "verification still failed after restart"
				failed_units="${failed_units} ${managed_name}"
				continue
			fi
			log_managed_unit "$systemd_user_manager_user" "$managed_name" "verified after restart in $(elapsed_since "$managed_verified_at")"
		fi
	done <<<"$managed_units_tsv"
	if [ -n "$failed_units" ]; then
		verification_failed_units="$failed_units"
		printf '%s\n' "failed managed unit verification:$failed_units" >&2
		return 1
	fi
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
			log_user_progress "$systemd_user_manager_user" "still waiting; elapsed=$(elapsed_since "$wait_started_at"); units=$(user_unit_progress_summary)"
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
	local failed_units apply_started_at total_units work_units skipped_units action_index managed_action_wait_index active_managed_actions
	local managed_name="" managed_started_at="" managed_action="" _start_mode="" _verify_command_b64=""
	local managed_units_tsv=""
	local -a managed_action_names=() managed_action_actions=() managed_action_pids=() managed_action_started_ats=()

	require_env SYSTEMD_USER_MANAGER_USER
	require_env SYSTEMD_USER_MANAGER_METADATA

	userctl_mode=user
	init_managed_user "$systemd_user_manager_user"
	failed_units=""
	total_units=0
	work_units=0
	skipped_units=0
	managed_action_wait_index=0
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
		while IFS="$metadata_field_sep" read -r managed_name managed_unit auto_start desired_state managed_timeout _reload_stamp _start_mode _repair_command_b64 _verify_command_b64; do
			total_units=$((total_units + 1))
			if ! start_managed_unit "$managed_name" "$managed_unit" "$auto_start" "$desired_state" "$managed_timeout" "$_start_mode" "$_repair_command_b64" "$_verify_command_b64"; then
				failed_units="${failed_units} ${managed_name}"
			elif [ "$managed_unit_outcome" = "start" ] || [ "$managed_unit_outcome" = "restart" ]; then
				work_units=$((work_units + 1))
				if [ -n "$managed_unit_action_pid" ]; then
					managed_action_names+=("$managed_name")
					managed_action_actions+=("$managed_unit_outcome")
					managed_action_pids+=("$managed_unit_action_pid")
					managed_action_started_ats+=("$managed_unit_action_started_at")
					active_managed_actions="$((${#managed_action_pids[@]} - managed_action_wait_index))"
					if [ "$start_concurrency" != -1 ] && [ "$active_managed_actions" -ge "$start_concurrency" ]; then
						wait_for_managed_action_index "$managed_action_wait_index"
						managed_action_wait_index="$((managed_action_wait_index + 1))"
					fi
				fi
			elif [ "$managed_unit_outcome" = "skip" ]; then
				skipped_units=$((skipped_units + 1))
			fi
		done <<<"$managed_units_tsv"
	fi

	for ((action_index = managed_action_wait_index; action_index < ${#managed_action_pids[@]}; action_index++)); do
		wait_for_managed_action_index "$action_index"
	done

	if [ -n "$failed_units" ]; then
		failed_units="$(prune_converged_failed_units "$failed_units" "$managed_units_tsv")"
	fi

	if [ -z "$failed_units" ] && ! verify_managed_units_from_metadata; then
		failed_units="${verification_failed_units:-metadata}"
	fi

	if [ -n "$failed_units" ]; then
		emit_failed_managed_unit_diagnostics "$failed_units" "$managed_units_tsv"
		if [ "$dry_run" = 1 ]; then
			log_user_progress "$systemd_user_manager_user" "preview failed after $(elapsed_since "$apply_started_at"): failed_units=$failed_units"
		else
			log_user_progress "$systemd_user_manager_user" "reconcile failed after $(elapsed_since "$apply_started_at"): failed_units=$failed_units"
		fi
		printf '%s\n' "failed managed units:$failed_units" >&2
		exit 1
	fi

	if [ "$dry_run" != 1 ] && migration_manager_gate_on; then
		log_user_progress "$systemd_user_manager_user" "migration gate is on; not starting $boot_ready_target_name"
	elif [ "$dry_run" != 1 ]; then
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
	reload_changed_managed_units_from_metadata
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
		IFS="$metadata_field_sep" read -r old_version old_user _ <<<"$old_header"
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
			IFS="$metadata_field_sep" read -r new_version _ _ <<<"$new_header"
			if [ "$old_version" != "$new_version" ]; then
				log_user_progress "$old_user" "metadata version changed; stopping removed units only"
				if ! stop_absent_units_after_metadata_version_change "$phase_mode" "$old_user" "$old_metadata_tsv" "$new_metadata_tsv"; then
					return 1
				fi
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

	if ! init_managed_user "$preview_user"; then
		log_user_progress "$preview_user" "dry-activate preview skipped: account unavailable"
		return 0
	fi
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
		IFS="$metadata_field_sep" read -r old_version old_user old_identity <<<"$state_header"
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
			IFS="$metadata_field_sep" read -r new_version _ _ <<<"$new_header"
			if [ "$old_version" != "$new_version" ]; then
				log_user_progress "$old_user" "applied metadata version changed; stopping removed units only"
				if ! stop_absent_units_after_metadata_version_change apply "$old_user" "$state_metadata_tsv" "$new_metadata_tsv"; then
					return 1
				fi
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
