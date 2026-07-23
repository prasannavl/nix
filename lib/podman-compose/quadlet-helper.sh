#!/usr/bin/env bash
# shellcheck disable=SC2154
set -Eeuo pipefail

quadlet_load_backend_metadata() {
	backend="$(jq -r '.backend // "compose"' "$podman_compose_metadata")"
	[ "$backend" = quadlet ] || {
		printf '%s\n' "expected Quadlet metadata for ${podman_compose_service_name}" >&2
		return 1
	}
	quadlet_container_unit="$(jq -r '.backendData.quadlet.containerUnit // empty' "$podman_compose_metadata")"
	quadlet_container_name="$(jq -r '.backendData.quadlet.containerName // empty' "$podman_compose_metadata")"
	quadlet_source_path="$(jq -r '.backendData.quadlet.sourcePath // empty' "$podman_compose_metadata")"
	quadlet_labels_json="$(jq -c '.backendData.quadlet.labels // {}' "$podman_compose_metadata")"
	mapfile -t quadlet_runtime_units < <(jq -r '.backendData.quadlet.runtimeUnits[]?' "$podman_compose_metadata")
	[ -n "$quadlet_container_unit" ] && [ -n "$quadlet_container_name" ] && [ -n "$quadlet_source_path" ] && [ "${#quadlet_runtime_units[@]}" -gt 0 ]
}

quadlet_load_metadata() {
	load_metadata
	quadlet_load_backend_metadata
}

quadlet_unit_state() {
	local active_state fragment_path load_state source_path state
	state="$(systemctl --user show \
		--property=LoadState \
		--property=ActiveState \
		--property=SourcePath \
		--property=FragmentPath \
		--value \
		"$quadlet_container_unit")" || {
		printf 'cannot query state of Quadlet unit %s\n' "$quadlet_container_unit" >&2
		return 1
	}
	load_state="$(sed -n '1p' <<<"$state")"
	active_state="$(sed -n '2p' <<<"$state")"
	source_path="$(sed -n '3p' <<<"$state")"
	fragment_path="$(sed -n '4p' <<<"$state")"
	if [ "$load_state" = loaded ]; then
		if [ "$source_path" != "$quadlet_source_path" ]; then
			printf 'refusing unowned Quadlet unit %s (source=%s expected=%s)\n' \
				"$quadlet_container_unit" "$source_path" "$quadlet_source_path" >&2
			return 1
		fi
		case "$fragment_path" in
		"$runtime_dir/systemd/generator/$quadlet_container_unit" | \
			"$runtime_dir/systemd/generator.early/$quadlet_container_unit" | \
			"$runtime_dir/systemd/generator.late/$quadlet_container_unit") ;;
		*)
			printf 'refusing unowned Quadlet unit %s (fragment=%s)\n' \
				"$quadlet_container_unit" "$fragment_path" >&2
			return 1
			;;
		esac
	fi
	case "${load_state}:${active_state}" in
	loaded:active) printf '%s\n' active ;;
	loaded:inactive | loaded:failed) printf '%s\n' inactive ;;
	not-found:inactive) printf '%s\n' absent ;;
	*)
		printf 'indeterminate Quadlet unit state for %s (load=%s active=%s)\n' \
			"$quadlet_container_unit" "$load_state" "$active_state" >&2
		return 1
		;;
	esac
}

quadlet_unit_active() {
	[ "$(quadlet_unit_state)" = active ]
}

quadlet_unit_inactive() {
	case "$(quadlet_unit_state)" in
	inactive | absent) return 0 ;;
	*) return 1 ;;
	esac
}

quadlet_container_json() {
	podman_no_notify container inspect "$quadlet_container_name"
}

quadlet_container_running_and_labeled() {
	local state_json
	state_json="$(quadlet_container_json)" || return 1
	jq -e --argjson expected "$quadlet_labels_json" '
		.[0]
		| select((.State.Status // "") == "running")
		| (.Config.Labels // {}) as $actual
		| all($expected | to_entries[]; $actual[.key] == .value)
	' <<<"$state_json" >/dev/null
}

quadlet_container_readiness_state() {
	local state_json
	state_json="$(quadlet_container_json)" || return 1
	jq -r --argjson expected "$quadlet_labels_json" '
		.[0]
		| (.Config.Labels // {}) as $actual
		| if (.State.Status // "") != "running"
			or (all($expected | to_entries[]; $actual[.key] == .value) | not)
		  then "invalid"
		  else ((.State.Health.Status // "none") | ascii_downcase) as $health
		  | if $health == "" or $health == "none" or $health == "healthy" then "ready"
		    elif $health == "starting" then "starting"
		    elif $health == "unhealthy" then "unhealthy"
		    else "invalid"
		    end
		  end
	' <<<"$state_json"
}

quadlet_container_labeled() {
	local state_json
	state_json="$(quadlet_container_json)" || return 1
	jq -e --argjson expected "$quadlet_labels_json" '
		.[0]
		| (.Config.Labels // {}) as $actual
		| all($expected | to_entries[]; $actual[.key] == .value)
	' <<<"$state_json" >/dev/null
}

quadlet_container_absent() {
	local status=0
	podman_no_notify container exists "${quadlet_container_name}" >/dev/null 2>&1 || status=$?
	case "${status}" in
	0)
		return 1
		;;
	1)
		return 0
		;;
	*)
		printf 'cannot determine whether Quadlet container %s exists (status=%s)\n' \
			"${quadlet_container_name}" "${status}" >&2
		return 1
		;;
	esac
}

quadlet_start_postcondition() {
	quadlet_unit_active && quadlet_container_running_and_labeled
}

quadlet_cleanup_postcondition() {
	quadlet_unit_inactive && quadlet_container_absent
}

quadlet_runtime_preflight_recreate_status() {
	local exists_status=0 unit_state
	unit_state="$(quadlet_unit_state)" || return 2
	podman_no_notify container exists "$quadlet_container_name" || exists_status="$?"
	case "$exists_status" in
	0)
		if ! quadlet_container_labeled; then
			printf 'refusing to mutate container %s because its ownership labels do not match %s\n' \
				"$quadlet_container_name" "$podman_compose_service_name" >&2
			return 2
		fi
		if [ "$unit_state" = active ] && quadlet_container_running_and_labeled; then
			return 1
		fi
		return 0
		;;
	1)
		if [ "$unit_state" = inactive ] || [ "$unit_state" = absent ]; then
			return 1
		fi
		return 0
		;;
	*) return 2 ;;
	esac
}

quadlet_runtime_preflight_cleanup() {
	local exists_status=0
	podman_no_notify container exists "$quadlet_container_name" >/dev/null 2>&1 || exists_status="$?"
	case "$exists_status" in
	0)
		if ! quadlet_container_labeled; then
			printf 'refusing to clean container %s because its ownership labels do not match %s\n' \
				"$quadlet_container_name" "$podman_compose_service_name" >&2
			return 1
		fi
		;;
	1) ;;
	*) return 1 ;;
	esac
	quadlet_stop_private_unit || return 1
	if ! quadlet_container_absent; then
		quadlet_container_labeled || return 1
		podman_no_notify rm --force "$quadlet_container_name" || true
	fi
	quadlet_cleanup_postcondition
}

quadlet_stop_private_unit() {
	local unit_state
	unit_state="${1:-}"
	if [ -z "$unit_state" ]; then
		unit_state="$(quadlet_unit_state)" || return 1
	fi
	case "$unit_state" in
	active) systemctl --user stop "$quadlet_container_unit" ;;
	inactive | absent) return 0 ;;
	*) return 1 ;;
	esac
}

quadlet_failed_start_cleanup() {
	if ! quadlet_stop_private_unit; then
		leave_rootless_runtime_dirty "failed Quadlet start cleanup could not prove private-unit ownership for ${podman_compose_service_name}"
		return 1
	fi
	if quadlet_cleanup_postcondition; then
		rollback_rootless_mutation_clean
		return 0
	fi
	leave_rootless_runtime_dirty "failed Quadlet start cleanup was indeterminate for ${podman_compose_service_name}"
	return 1
}

quadlet_start_transaction() {
	local status=0 unit_state
	begin_rootless_mutation "quadlet start transaction" || return "$?"
	if ! backend_transition_admit; then
		rollback_rootless_mutation_clean
		return 1
	fi
	if ! unit_state="$(quadlet_unit_state)"; then
		rollback_rootless_mutation_clean
		return 1
	fi
	if ! quadlet_stop_private_unit "$unit_state"; then
		leave_rootless_runtime_dirty "Quadlet private-unit ownership was indeterminate for ${podman_compose_service_name}"
		return 1
	fi
	if ! quadlet_cleanup_postcondition; then
		leave_rootless_runtime_dirty "Quadlet replacement cleanup was indeterminate for ${podman_compose_service_name}"
		return 1
	fi
	run_bootstrap_phase || status="$?"
	if [ "$status" -eq 0 ]; then
		if ! unit_state="$(quadlet_unit_state)"; then
			status=1
		elif [ "$unit_state" = absent ]; then
			printf 'declared Quadlet unit is not loaded: %s\n' "$quadlet_container_unit" >&2
			status=1
		else
			systemctl --user start "$quadlet_container_unit" || status="$?"
		fi
	fi
	if [ "$status" -eq 0 ] && ! quadlet_start_postcondition; then
		printf '%s\n' "Quadlet start did not reach its unit/container postcondition for ${podman_compose_service_name}" >&2
		status=1
	fi
	if [ "$status" -eq 0 ]; then
		commit_rootless_mutation
		return 0
	fi
	quadlet_failed_start_cleanup || true
	return "$status"
}

quadlet_start_locked() {
	local staged="$1" status=0
	assert_adoption_allowed
	ensure_runtime_dirs
	if helper_invoked_as_script && start_in_progress_active; then
		printf '%s\n' "Quadlet start is already in progress for ${podman_compose_service_name}" >&2
		return "$compose_start_stuck_exit_status"
	fi
	lock_lifecycle_exclusive
	rm -f -- "$failed_start_cleanup_complete_path"
	clear_removal_policy_marker
	if [ "$staged" = false ]; then
		record_staging_runtime_state
		stage_runtime_files
	elif ! verify_staged_runtime_files; then
		unlock_lifecycle_exclusive
		return 1
	fi
	mark_start_in_progress "$$"
	quadlet_start_transaction || status="$?"
	if [ "$status" -eq 0 ]; then
		record_applied_recreate_state
	fi
	clear_start_in_progress
	unlock_lifecycle_exclusive
	return "$status"
}

quadlet_cmd_start() {
	quadlet_load_metadata
	quadlet_start_locked false && run_post_start_hooks
}

quadlet_cmd_start_staged() {
	quadlet_load_metadata
	quadlet_start_locked true
}

quadlet_stop_transaction() {
	local outcome="${1:-commit}" preflight_policy="${2:-current}" run_hooks="${3:-false}" unit_state
	begin_rootless_mutation "quadlet stop transaction" "$preflight_policy" || return "$?"
	if ! unit_state="$(quadlet_unit_state)"; then
		rollback_rootless_mutation_clean
		return 1
	fi
	if [ "$run_hooks" = true ] && ! run_pre_stop_hooks; then
		rollback_rootless_mutation_clean
		return 1
	fi
	quadlet_stop_private_unit "$unit_state" || {
		leave_rootless_runtime_dirty "Quadlet private-unit ownership was indeterminate for ${podman_compose_service_name}"
		return 1
	}
	if quadlet_cleanup_postcondition; then
		case "$outcome" in
		commit) commit_rootless_mutation ;;
		rollback) rollback_rootless_mutation_clean ;;
		esac
		return 0
	fi
	leave_rootless_runtime_dirty "Quadlet stop cleanup was indeterminate for ${podman_compose_service_name}"
	return 1
}

quadlet_cmd_stop() {
	quadlet_load_metadata
	lock_lifecycle_exclusive
	mark_stop_in_progress
	if ! quadlet_stop_transaction commit drain true; then
		clear_stop_in_progress
		unlock_lifecycle_exclusive
		return 1
	fi
	clear_stop_in_progress
	unlock_lifecycle_exclusive
}

quadlet_cmd_post_stop() {
	quadlet_load_metadata
	lock_lifecycle_exclusive
	if ! quadlet_cleanup_postcondition; then
		if ! quadlet_stop_transaction rollback drain; then
			unlock_lifecycle_exclusive
			return 1
		fi
	fi
	cleanup_runtime_files
	clear_start_in_progress
	clear_stop_in_progress
	clear_removal_policy_marker
	unlock_lifecycle_exclusive
}

quadlet_cmd_reload() {
	quadlet_load_metadata
	lock_lifecycle_exclusive
	run_pre_stop_hooks || {
		unlock_lifecycle_exclusive
		return 1
	}
	quadlet_stop_transaction || {
		unlock_lifecycle_exclusive
		return 1
	}
	record_staging_runtime_state
	stage_runtime_files
	quadlet_start_transaction || {
		unlock_lifecycle_exclusive
		return 1
	}
	record_applied_recreate_state
	unlock_lifecycle_exclusive
	run_post_start_hooks
}

quadlet_cmd_verify() {
	local deadline health_state now
	quadlet_load_metadata
	deadline="$(($(now_epoch) + verify_transition_wait_seconds))"
	while true; do
		wait_for_verify_transition || return 1
		lock_lifecycle_shared
		if verify_transition_active; then
			unlock_lifecycle_shared
			continue
		fi
		if ! verify_staged_runtime_files ||
			! verify_runtime_state_current ||
			! quadlet_unit_active; then
			unlock_lifecycle_shared
			return 1
		fi
		if ! health_state="$(quadlet_container_readiness_state)"; then
			unlock_lifecycle_shared
			return 1
		fi
		case "$health_state" in
		ready)
			if run_verify_command; then
				unlock_lifecycle_shared
				return 0
			fi
			unlock_lifecycle_shared
			return 1
			;;
		starting | unhealthy)
			unlock_lifecycle_shared
			now="$(now_epoch)"
			if [ "$now" -ge "$deadline" ]; then
				printf 'Quadlet container health stayed %s for %s\n' \
					"$health_state" "$podman_compose_service_name" >&2
				return 1
			fi
			sleep 1
			;;
		invalid)
			printf 'Quadlet container readiness is %s for %s\n' \
				"$health_state" "$podman_compose_service_name" >&2
			unlock_lifecycle_shared
			return 1
			;;
		*)
			unlock_lifecycle_shared
			return 1
			;;
		esac
	done
}

quadlet_pull_images() {
	local attempt image
	for image in "${declared_images[@]}"; do
		attempt=1
		while ! podman_no_notify pull "$image"; do
			if [ "$attempt" -ge "$image_pull_retry_attempts" ]; then
				return 1
			fi
			attempt="$((attempt + 1))"
			sleep "$image_pull_retry_delay_seconds"
		done
	done
}

quadlet_cmd_image_pull() {
	local mutation_rc=0
	quadlet_load_metadata
	assert_adoption_allowed
	ensure_runtime_dirs
	if image_pull_state_current; then
		record_image_pull_status skipped
		return 0
	fi
	if declared_images_present; then
		if lock_lifecycle_exclusive_timeout 1; then
			record_image_pull_state
			unlock_lifecycle_exclusive
		fi
		record_image_pull_status skipped
		return 0
	fi
	if [ "${#declared_images[@]}" -eq 0 ]; then
		record_image_pull_status skipped
		return 0
	fi
	begin_image_pull_mutation "quadlet image pull" || mutation_rc="$?"
	if [ "$mutation_rc" -ne 0 ]; then
		if [ "$image_pull_preflight_policy" = prepare ] && [ "$mutation_rc" -eq 75 ]; then
			record_image_pull_status deferred
			return 0
		fi
		return "$mutation_rc"
	fi
	if ! quadlet_pull_images; then
		rollback_rootless_mutation_clean
		unlock_lifecycle_exclusive
		return 1
	fi
	commit_rootless_mutation
	record_image_pull_state
	record_image_pull_status pulled
	unlock_lifecycle_exclusive
}

quadlet_cmd_remove() {
	quadlet_load_metadata
	if removal_has_no_staged_runtime; then
		return 0
	fi
	write_removal_policy_marker
	if ! systemctl --user stop "${podman_compose_service_name}.service"; then
		clear_removal_policy_marker
		return 1
	fi
	if has_removal_policy_marker; then
		lock_lifecycle_exclusive
		quadlet_stop_transaction || {
			unlock_lifecycle_exclusive
			return 1
		}
		cleanup_runtime_files
		clear_removal_policy_marker
		unlock_lifecycle_exclusive
	fi
}

quadlet_cmd_logs() {
	quadlet_load_metadata
	journalctl --user-unit "$quadlet_container_unit" "$@"
}

quadlet_main() {
	case "${1-}" in
	stage) cmd_stage ;;
	bootstrap-internal) cmd_bootstrap_internal ;;
	link-files) cmd_link_files ;;
	cleanup-files) cmd_cleanup_files ;;
	post-stop) quadlet_cmd_post_stop ;;
	verify) quadlet_cmd_verify ;;
	reload) quadlet_cmd_reload ;;
	repair | start) quadlet_cmd_start ;;
	start-staged) quadlet_cmd_start_staged ;;
	reconcile) cmd_reconcile ;;
	stop) quadlet_cmd_stop ;;
	remove) quadlet_cmd_remove ;;
	image-pull) quadlet_cmd_image_pull ;;
	logs)
		shift
		quadlet_cmd_logs "$@"
		;;
	*)
		printf '%s\n' "unsupported Quadlet helper command: ${1-}" >&2
		return 1
		;;
	esac
}
