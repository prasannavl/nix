#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

init_vars() {
	podman_compose_metadata="${NIX_PODMAN_COMPOSE_METADATA-}"
	podman_compose_service_name="${NIX_PODMAN_COMPOSE_SERVICE_NAME-}"
	backend="compose"

	runtime_dir="${XDG_RUNTIME_DIR-}"
	generated_dir=""
	manifest_path=""
	lifecycle_lock_path=""
	start_in_progress_path=""
	stop_in_progress_path=""
	failed_start_cleanup_complete_path=""
	rootless_mutation_marker_path=""
	rootless_runtime_dirty_path=""
	compose_dns_correction_marker_path=""
	state_path=""
	runtime_state_version=3
	runtime_state_kind="podman-compose-runtime-state"
	compose_start_timeout_unit=""
	adoption_stamp=""
	working_dir=""
	desired_state="running"
	reconcile_policy="auto"
	removal_policy="delete"
	adopt_existing="false"
	recreate_tag="0"
	recreate_stamp=""
	recreate_class_stamp=""
	image_pull_stamp=""
	long_running="true"
	reload_method="restart"
	reload_signal="HUP"
	restart_stamp=""
	monitor_interval=10
	compose_start_default_timeout_seconds=900
	compose_provider_timeout_seconds="${NIX_PODMAN_COMPOSE_PROVIDER_TIMEOUT_SECONDS:-}"
	bootstrap_timeout_seconds=300
	compose_up_no_progress_seconds="${NIX_PODMAN_COMPOSE_UP_NO_PROGRESS_SECONDS:-60}"
	compose_start_stuck_exit_status=75
	compose_start_project_dns_reloadable_exit_status=77
	compose_dns_indeterminate_exit_status=79
	compose_dns_lookup_failed_exit_status=42
	compose_monitor_timeout_seconds=20
	compose_monitor_failure_grace_seconds=45
	compose_stop_default_timeout_seconds=45
	podman_rootless_lifecycle_lock_depth=0
	podman_rootless_observation_lock_depth=0
	rootless_runtime_preflight_suppressed=0
	post_stop_lock_timeout_seconds="${NIX_PODMAN_COMPOSE_POST_STOP_LOCK_TIMEOUT_SECONDS:-30}"
	post_stop_rootless_lock_timeout_seconds="${NIX_PODMAN_COMPOSE_POST_STOP_ROOTLESS_LOCK_TIMEOUT_SECONDS:-30}"
	# Normal stop transactions are already bounded by systemd TimeoutStopSec.
	# A second default deadline can fail queued graph members before their turn.
	stop_rootless_lock_timeout_seconds="${NIX_PODMAN_COMPOSE_STOP_ROOTLESS_LOCK_TIMEOUT_SECONDS:-0}"
	verify_transition_wait_seconds="${NIX_PODMAN_COMPOSE_VERIFY_TRANSITION_WAIT_SECONDS:-30}"
	image_pull_retry_attempts="${NIX_PODMAN_COMPOSE_IMAGE_PULL_RETRY_ATTEMPTS:-10}"
	image_pull_retry_delay_seconds="${NIX_PODMAN_COMPOSE_IMAGE_PULL_RETRY_DELAY_SECONDS:-1}"
	image_pull_status_file="${NIX_PODMAN_COMPOSE_IMAGE_PULL_STATUS_FILE:-}"
	image_pull_preflight_policy="${NIX_PODMAN_COMPOSE_IMAGE_PULL_PREFLIGHT_POLICY:-current}"
	prepare_lock_timeout_seconds="${NIX_PODMAN_COMPOSE_PREPARE_LOCK_TIMEOUT_SECONDS:-1}"
	runtime_preflight_metadata="${NIX_PODMAN_COMPOSE_RUNTIME_PREFLIGHT_METADATA-}"
	runtime_preflight_token=""
	runtime_preflight_stamp_path=""
	runtime_preflight_required_path=""
	runtime_preflight_repaired=0
	runtime_preflight_had_stale_marker=0
	aardvark_dns_configs_pruned=0
	compose_start_force_recreate=0
	compose_up_project_dns_reload_attempted=0
	compose_dns_dependencies_loaded=0
	compose_dns_dependencies_json='[]'

	compose_args=()
	podman_compose_base_args=()
	compose_file_args=()
	pull_compose_file_args=()
	declared_images=()
	local_image_refs=()
	local_image_runtime_refs=()
	local_image_load_refs=()
	local_image_tars=()
	expected_compose_services=()
	reload_services=()
	verify_command=()
	quadlet_runtime_units=()
	quadlet_container_unit=""
	quadlet_container_name=""
	quadlet_source_path=""
	quadlet_labels_json='{}'
	supervised_active_pid=""
	supervised_active_pid_file=""
}

load_runtime_preflight_metadata() {
	require_env NIX_PODMAN_COMPOSE_RUNTIME_PREFLIGHT_METADATA
	require_env NIX_PODMAN_COMPOSE_SERVICE_NAME
	require_env XDG_RUNTIME_DIR

	runtime_dir="$XDG_RUNTIME_DIR"
	podman_compose_service_name="$NIX_PODMAN_COMPOSE_SERVICE_NAME"
	runtime_preflight_token="$(jq -r '.token' "$runtime_preflight_metadata")"
	rootless_mutation_marker_path="$runtime_dir/podman-compose/rootless-mutations/${podman_compose_service_name}"
	rootless_runtime_dirty_path="$runtime_dir/podman-compose/runtime-dirty"
	runtime_preflight_stamp_path="$runtime_dir/podman-compose/runtime-preflight.stamp"
	runtime_preflight_required_path="$runtime_dir/podman-compose/runtime-preflight-required"
	case "$runtime_preflight_token" in
	"" | null)
		printf '%s\n' "podman runtime preflight metadata has no token: $runtime_preflight_metadata" >&2
		return 1
		;;
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

now_epoch() {
	date +%s
}

helper_invoked_as_script() {
	[ "${NIX_PODMAN_COMPOSE_HELPER_TOPLEVEL-}" = "1" ] || [ "${BASH_SOURCE[0]}" = "$0" ]
}

load_metadata() {
	local compose_file
	require_env NIX_PODMAN_COMPOSE_METADATA
	require_env NIX_PODMAN_COMPOSE_SERVICE_NAME
	require_env XDG_RUNTIME_DIR

	manifest_path="$runtime_dir/podman-compose/${podman_compose_service_name}.manifest"
	working_dir="$(jq -r '.workingDir' "$podman_compose_metadata")"
	backend="$(jq -r '.backend // "compose"' "$podman_compose_metadata")"
	desired_state="$(jq -r '.state // "running"' "$podman_compose_metadata")"
	reconcile_policy="$(jq -r '.reconcilePolicy // "auto"' "$podman_compose_metadata")"
	generated_dir="$working_dir/.podman-compose"
	lifecycle_lock_path="$generated_dir/lifecycle.lock"
	start_in_progress_path="$generated_dir/start-in-progress"
	stop_in_progress_path="$generated_dir/stop-in-progress"
	failed_start_cleanup_complete_path="$generated_dir/failed-start-cleanup-complete"
	rootless_mutation_marker_path="$runtime_dir/podman-compose/rootless-mutations/${podman_compose_service_name}"
	rootless_runtime_dirty_path="$runtime_dir/podman-compose/runtime-dirty"
	runtime_preflight_stamp_path="$runtime_dir/podman-compose/runtime-preflight.stamp"
	runtime_preflight_required_path="$runtime_dir/podman-compose/runtime-preflight-required"
	compose_dns_correction_marker_path="$generated_dir/dns-correction-attempted"
	state_path="$generated_dir/state.json"
	adoption_stamp="$(jq -r '.adoptionStamp // ""' "$podman_compose_metadata")"
	recreate_tag="$(jq -r '.recreateTag // "0"' "$podman_compose_metadata")"
	recreate_stamp="$(jq -r '.recreateStamp // ""' "$podman_compose_metadata")"
	recreate_class_stamp="$(jq -r '.recreateClassStamp // (.recreateStamp // "")' "$podman_compose_metadata")"
	image_pull_stamp="$(jq -r '.imagePullStamp // ""' "$podman_compose_metadata")"
	removal_policy="$(jq -r '.removalPolicy // "delete"' "$podman_compose_metadata")"
	adopt_existing="$(jq -r '.adopt // false' "$podman_compose_metadata")"
	long_running="$(jq -r 'if has("longRunning") then .longRunning else true end' "$podman_compose_metadata")"
	reload_method="$(jq -r '.reload.method // "restart"' "$podman_compose_metadata")"
	reload_signal="$(jq -r '.reload.signal // "HUP"' "$podman_compose_metadata")"
	restart_stamp="$(jq -r '.restartStamp // ""' "$podman_compose_metadata")"
	bootstrap_timeout_seconds="$(jq -r '.timeoutBootstrapSeconds // 300' "$podman_compose_metadata")"

	compose_args=()
	while IFS= read -r compose_arg; do
		[ -n "$compose_arg" ] || continue
		compose_args+=("$compose_arg")
	done < <(jq -r '.composeArgs[]?' "$podman_compose_metadata")

	compose_file_args=()
	while IFS= read -r compose_file; do
		compose_file_args+=(-f "$compose_file")
	done < <(jq -r '.composeFiles[]?' "$podman_compose_metadata")

	pull_compose_file_args=()
	while IFS= read -r compose_file; do
		pull_compose_file_args+=(-f "$compose_file")
	done < <(jq -r '.pullComposeFiles[]?' "$podman_compose_metadata")

	declared_images=()
	while IFS= read -r image; do
		[ -n "$image" ] || continue
		declared_images+=("$image")
	done < <(jq -r '.declaredImages[]?' "$podman_compose_metadata")

	local_image_refs=()
	local_image_runtime_refs=()
	local_image_load_refs=()
	local_image_tars=()
	while IFS= read -r encoded; do
		[ -n "$encoded" ] || continue
		image_json="$(printf '%s' "$encoded" | base64 -d)"
		image_ref="$(printf '%s' "$image_json" | jq -r '.imageRef')"
		[ -n "$image_ref" ] || continue
		local_image_refs+=("$image_ref")
		local_image_runtime_refs+=("$(printf '%s' "$image_json" | jq -r '.runtimeRef')")
		local_image_load_refs+=("$(printf '%s' "$image_json" | jq -r '.loadRef // ""')")
		local_image_tars+=("$(printf '%s' "$image_json" | jq -r '.imageTar')")
	done < <(jq -r '.localImages[]? | @base64' "$podman_compose_metadata")

	expected_compose_services=()
	while IFS= read -r compose_service; do
		[ -n "$compose_service" ] || continue
		expected_compose_services+=("$compose_service")
	done < <(jq -r '.expectedComposeServices[]?' "$podman_compose_metadata")

	reload_services=()
	while IFS= read -r compose_service; do
		[ -n "$compose_service" ] || continue
		reload_services+=("$compose_service")
	done < <(jq -r '.reload.services[]?' "$podman_compose_metadata")

	verify_command=()
	while IFS= read -r command_arg; do
		verify_command+=("$command_arg")
	done < <(jq -r '.verifyCommand[]?' "$podman_compose_metadata")
}

remove_path_if_exists() {
	local path
	path="$1"
	if [ -e "$path" ] || [ -L "$path" ]; then
		rm -rf -- "$path"
	fi
}

ensure_runtime_dirs() {
	install -d -m 0750 "$working_dir"
	install -d -m 0750 "$generated_dir"
	install -d -m 0700 "$runtime_dir/podman-compose"
}

lock_lifecycle_exclusive() {
	install -d -m 0750 "$generated_dir"
	exec 9>"$lifecycle_lock_path"
	flock -x 9
}

lock_lifecycle_exclusive_timeout() {
	local timeout_seconds
	timeout_seconds="$1"
	install -d -m 0750 "$generated_dir"
	exec 9>"$lifecycle_lock_path"
	if ! flock_timeout 9 "$timeout_seconds"; then
		exec 9>&-
		return 1
	fi
}

unlock_lifecycle_exclusive() {
	flock -u 9
	exec 9>&-
}

lock_lifecycle_shared() {
	install -d -m 0750 "$generated_dir"
	exec 8<>"$lifecycle_lock_path"
	flock -s 8
}

unlock_lifecycle_shared() {
	flock -u 8
	exec 8>&-
}

close_lifecycle_fds_for_child() {
	exec 6>&- 2>/dev/null || true
	exec 7>&- 2>/dev/null || true
	exec 8>&- 2>/dev/null || true
	exec 9>&- 2>/dev/null || true
}

flock_timeout() {
	local fd timeout_seconds started_at now
	fd="$1"
	timeout_seconds="$2"
	started_at="$(now_epoch)"
	while true; do
		if flock -n "$fd"; then
			return 0
		fi
		now="$(now_epoch)"
		if [ "$now" -ge "$((started_at + timeout_seconds))" ]; then
			return 1
		fi
		sleep 0.2
	done
}

podman_no_notify() {
	env -u NOTIFY_SOCKET -u WATCHDOG_PID -u WATCHDOG_USEC podman "$@"
}

podman_no_notify_timeout() {
	local timeout_seconds
	timeout_seconds="$1"
	shift
	env -u NOTIFY_SOCKET -u WATCHDOG_PID -u WATCHDOG_USEC timeout -k 5s "${timeout_seconds}s" podman "$@"
}

run_lifecycle_hook_command() {
	local hook_name command ignore_failure status
	hook_name="$1"
	command="$2"
	ignore_failure=0

	if [ "${command#-}" != "$command" ]; then
		ignore_failure=1
		command="${command#-}"
	fi
	[ -n "$command" ] || return 0

	if (
		close_lifecycle_fds_for_child
		if [ -d "$working_dir" ]; then
			cd "$working_dir"
		else
			cd /
		fi
		/bin/sh -eu -c "$command"
	); then
		return 0
	else
		status="$?"
	fi

	if [ "$ignore_failure" -eq 1 ]; then
		printf '%s\n' "podman compose ${hook_name} hook failed with status ${status}; ignoring"
		return 0
	fi
	printf '%s\n' "podman compose ${hook_name} hook failed with status ${status}" >&2
	return "$status"
}

run_lifecycle_hooks() {
	local hook_name metadata_key encoded command
	hook_name="$1"
	metadata_key="$2"
	while IFS= read -r encoded; do
		[ -n "$encoded" ] || continue
		command="$(printf '%s' "$encoded" | base64 -d)"
		run_lifecycle_hook_command "$hook_name" "$command" || return "$?"
	done < <(jq -r --arg key "$metadata_key" '.[$key][]? | @base64' "$podman_compose_metadata")
}

load_local_images() {
	local index image_ref runtime_ref load_ref image_tar load_output loaded_ref

	for index in "${!local_image_refs[@]}"; do
		image_ref="${local_image_refs[$index]}"
		runtime_ref="${local_image_runtime_refs[$index]}"
		load_ref="${local_image_load_refs[$index]-}"
		image_tar="${local_image_tars[$index]}"

		if (
			close_lifecycle_fds_for_child
			podman_no_notify image exists "$runtime_ref" >/dev/null 2>&1
		); then
			continue
		fi

		printf '%s\n' "loading local image ${image_ref} from ${image_tar}"
		(
			close_lifecycle_fds_for_child
			load_output="$(podman_no_notify load --input "$image_tar")"
			printf '%s\n' "$load_output"
			if [ -z "$load_ref" ]; then
				loaded_ref="$(
					printf '%s\n' "$load_output" |
						sed -n -e 's/^Loaded image: //p' -e 's/^Loaded image(s): //p' |
						tail -n 1
				)"
				load_ref="$loaded_ref"
			fi
			if [ -z "$load_ref" ]; then
				printf '%s\n' "podman load did not report an image ref for ${image_tar}; cannot tag ${runtime_ref}" >&2
				return 1
			fi
			if [ "$load_ref" != "$runtime_ref" ]; then
				podman_no_notify tag "$load_ref" "$runtime_ref"
			fi
		)
	done
}

run_pre_start_hooks() {
	load_local_images
	run_lifecycle_hooks preStart preStart
}

run_bootstrap_phase() {
	local status=0
	if [ -z "${NIX_PODMAN_COMPOSE_HELPER_SELF-}" ]; then
		# Unit tests and sourced operator shells do not have the packaged helper
		# entrypoint. They still exercise the exact phase body.
		run_pre_start_hooks
		return
	fi
	timeout -k 5s "${bootstrap_timeout_seconds}s" "$NIX_PODMAN_COMPOSE_HELPER_SELF" bootstrap-internal || status="$?"
	if [ "$status" -ne 0 ]; then
		if [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
			printf '%s\n' "podman compose bootstrap exceeded ${bootstrap_timeout_seconds}s for ${podman_compose_service_name}" >&2
		fi
		return "$status"
	fi
}

mark_compose_dns_correction_attempted() {
	if [ -z "$compose_dns_correction_marker_path" ]; then
		compose_dns_correction_marker_path="$generated_dir/dns-correction-attempted"
	fi
	install -d -m 0750 "${compose_dns_correction_marker_path%/*}"
	: >"$compose_dns_correction_marker_path"
}

run_post_start_hooks() {
	run_lifecycle_hooks postStart postStart
}

run_verify_command() {
	[ "${#verify_command[@]}" -gt 0 ] || return 0
	(
		close_lifecycle_fds_for_child
		cd /
		"${verify_command[@]}"
	)
}

run_pre_stop_hooks() {
	run_lifecycle_hooks preStop preStop
}

adoption_state_matches() {
	[ -n "$adoption_stamp" ] || return 1
	[ -f "$state_path" ] || return 1
	runtime_state_matches
}

legacy_helper_shell_without_runtime_state() {
	[ -n "$adoption_stamp" ] || return 1
	[ -d "$working_dir" ] || return 1
	[ -d "$generated_dir" ] || return 1
	[ -e "$lifecycle_lock_path" ] || return 1
	[ ! -f "$state_path" ] || return 1
	[ ! -f "$(legacy_state_path)" ] || return 1
}

record_bootstrapped_runtime_state() {
	local tmp_state
	install -d -m 0750 "$generated_dir"
	tmp_state="${state_path}.tmp"
	jq -n -c \
		--argjson version "$runtime_state_version" \
		--arg kind "$runtime_state_kind" \
		--arg adoptionStamp "$adoption_stamp" \
		--arg reconcilePolicy "${reconcile_policy:-auto}" \
		--arg restartStamp "${restart_stamp:-}" \
		--arg recreateTag "${recreate_tag:-0}" \
		--arg recreateStamp "${recreate_stamp:-}" \
		--arg recreateClassStamp "${recreate_class_stamp:-${recreate_stamp:-}}" \
		'{
			version: $version,
			kind: $kind,
			adoptionStamp: $adoptionStamp,
			reconcilePolicy: $reconcilePolicy,
			restartStamp: $restartStamp,
			recreateTag: $recreateTag,
			recreateStamp: $recreateStamp,
			recreateClassStamp: $recreateClassStamp
		}' >"$tmp_state"
	chmod 0640 "$tmp_state"
	mv -f "$tmp_state" "$state_path"
}

bootstrap_legacy_runtime_state_if_needed() {
	legacy_helper_shell_without_runtime_state || return 0
	printf '%s\n' "Bootstrapping missing Podman compose helper state for legacy working directory: $working_dir"
	record_bootstrapped_runtime_state
}

working_dir_has_compose_containers() {
	local containers
	if ! containers="$(
		close_lifecycle_fds_for_child
		cd /
		podman_no_notify ps -a \
			--filter "label=com.docker.compose.project.working_dir=$working_dir" \
			--format '{{.ID}}'
	)"; then
		return 0
	fi
	[ -n "$containers" ]
}

working_dir_is_uninitialized_helper_shell() {
	local path rel
	[ -d "$working_dir" ] || return 1
	[ -d "$generated_dir" ] || return 1
	[ ! -f "$state_path" ] || return 1
	[ ! -f "$(legacy_state_path)" ] || return 1
	[ ! -f "$manifest_path" ] || return 1
	! working_dir_has_compose_containers || return 1

	while IFS= read -r path; do
		rel="${path#"$working_dir"/}"
		case "$rel" in
		.podman-compose | .podman-compose/lifecycle.lock) ;;
		*)
			if ! working_dir_path_is_declared_helper_staging "$path"; then
				return 1
			fi
			;;
		esac
	done < <(find "$working_dir" -mindepth 1 -print)
}

working_dir_path_is_declared_helper_staging() {
	local path
	path="$1"

	jq -e --arg path "$path" '
		def contains_path($parent; $child):
			$child == $parent or ($child | startswith($parent + "/"));

		any(.stagedDirs[]?.dst; contains_path(.; $path) or contains_path($path; .))
		or any(.stagedFiles[]?.dst; . == $path or contains_path($path; .))
		or any(.envSecretFiles[]?.dst; . == $path or contains_path($path; .))
		or any(.reload.dirs[]?.dst; contains_path(.; $path) or contains_path($path; .))
		or any(.reload.stagedFiles[]?.dst; . == $path or contains_path($path; .))
	' "$podman_compose_metadata" >/dev/null
}

assert_adoption_allowed() {
	if [ ! -e "$working_dir" ]; then
		return 0
	fi

	migrate_legacy_runtime_state_if_needed
	migrate_runtime_state_version_if_needed

	if adoption_state_matches; then
		return 0
	fi

	if working_dir_is_uninitialized_helper_shell; then
		printf '%s\n' "Recovering uninitialized Podman compose helper working directory: $working_dir"
		return 0
	fi

	bootstrap_legacy_runtime_state_if_needed
	if adoption_state_matches; then
		return 0
	fi

	if [ "$adopt_existing" = "true" ]; then
		printf '%s\n' "Adopting Podman compose working directory with unmatched helper state: $working_dir"
		return 0
	fi

	if [ -f "$state_path" ]; then
		printf '%s\n' "Refusing to manage Podman compose working directory with incompatible helper state: $working_dir; set adopt = true to adopt it" >&2
	else
		printf '%s\n' "Refusing to manage existing Podman compose working directory without compatible helper state: $working_dir; set adopt = true to adopt it" >&2
	fi
	exit 1
}

run_scoped() {
	local scope
	scope="$1"
	shift

	if [ "$scope" = "container" ]; then
		(
			close_lifecycle_fds_for_child
			podman_no_notify unshare "$@"
		)
	else
		(
			close_lifecycle_fds_for_child
			"$@"
		)
	fi
}

# apply_perms <path> <mode|null|none> <user|null> <group|null> <scope>
# Applies mode then chown. For scope=container, both operations are wrapped in
# `podman unshare` so uid/gid and mode changes are evaluated in the rootless
# container user namespace.
apply_perms() {
	local path mode user group scope chown_spec
	path="$1"
	mode="$2"
	user="$3"
	group="$4"
	scope="$5"

	if [ -n "$mode" ] && [ "$mode" != "null" ] && [ "$mode" != "none" ]; then
		run_scoped "$scope" chmod "$mode" "$path"
	fi

	if { [ -n "$user" ] && [ "$user" != "null" ]; } || { [ -n "$group" ] && [ "$group" != "null" ]; }; then
		chown_spec=""
		if [ -n "$user" ] && [ "$user" != "null" ]; then
			chown_spec="$user"
		fi
		if [ -n "$group" ] && [ "$group" != "null" ]; then
			chown_spec="${chown_spec}:${group}"
		fi
		run_scoped "$scope" chown "$chown_spec" "$path"
	fi
}

prepare_staged_dir_for_write() {
	local path mode user group scope once
	path="$1"
	mode="$2"
	user="$3"
	group="$4"
	scope="$5"
	once="$6"

	if [ -e "$path" ] || [ -L "$path" ]; then
		if [ ! -d "$path" ] || [ -L "$path" ]; then
			remove_path_if_exists "$path"
			install -d -m 0700 "$path"
			if [ "$once" = "true" ]; then
				apply_perms "$path" "$mode" "$user" "$group" "$scope"
			fi
			return
		fi

		if [ "$once" = "true" ]; then
			return
		fi

		if [ "$scope" = "container" ]; then
			# Container-scoped dirs are finalized to non-stack host ids. Reset to
			# userns root first so this helper can restage files on the next run.
			# Contents are intentionally untouched; data dirs survive restarts.
			run_scoped "$scope" chown 0:0 "$path"
		fi
		run_scoped "$scope" chmod u+rwx "$path"
	else
		install -d -m 0700 "$path"
		if [ "$once" = "true" ]; then
			apply_perms "$path" "$mode" "$user" "$group" "$scope"
		fi
	fi
}

prepare_staged_dirs_for_write() {
	local dst mode user group scope once
	while IFS=$'\t' read -r dst mode user group scope once; do
		[ -n "$dst" ] || continue
		prepare_staged_dir_for_write "$dst" "$mode" "$user" "$group" "$scope" "$once"
	done < <(jq -r '(.stagedDirs // [] | sort_by(.dst | length))[] | [.dst, (if has("mode") then (.mode // "null") else "0750" end), (.user // "null"), (.group // "null"), (.scope // "host"), (.once // false)] | @tsv' "$podman_compose_metadata")
}

finalize_staged_dirs() {
	local dst mode user group scope once
	while IFS=$'\t' read -r dst mode user group scope once; do
		[ -n "$dst" ] || continue
		if [ "$once" = "true" ]; then
			continue
		fi
		if [ ! -d "$dst" ] || [ -L "$dst" ]; then
			remove_path_if_exists "$dst"
			install -d -m 0700 "$dst"
		fi
		apply_perms "$dst" "$mode" "$user" "$group" "$scope"
	done < <(jq -r '(.stagedDirs // [] | sort_by(.dst | length) | reverse)[] | [.dst, (if has("mode") then (.mode // "null") else "0750" end), (.user // "null"), (.group // "null"), (.scope // "host"), (.once // false)] | @tsv' "$podman_compose_metadata")
}

stage_runtime_file() {
	local src dst dst_dir dst_dir_mode mode user group scope tmp_file tmp_manifest
	src="$1"
	dst="$2"
	dst_dir="$3"
	dst_dir_mode="$4"
	mode="$5"
	user="$6"
	group="$7"
	scope="$8"
	tmp_manifest="$9"
	tmp_file="${dst}.tmp"

	install -d -m "$dst_dir_mode" "$dst_dir"
	remove_path_if_exists "$dst"
	remove_path_if_exists "$tmp_file"
	# Write to a temp path first so bind-mounted consumers never see a partially
	# copied file.
	cp -f --preserve=mode -- "$src" "$tmp_file"
	apply_perms "$tmp_file" "$mode" "$user" "$group" "$scope"
	mv -f "$tmp_file" "$dst"
	printf '%s\n' "$dst" >>"$tmp_manifest"
}

stage_runtime_files() {
	local tmp_manifest line src dst dst_dir dst_dir_mode mode user group scope
	tmp_manifest="${manifest_path}.tmp"

	remove_path_if_exists "$tmp_manifest"
	: >"$tmp_manifest"

	prepare_staged_dirs_for_write

	while IFS=$'\t' read -r src dst dst_dir dst_dir_mode mode user group scope; do
		[ -n "$src" ] || continue
		stage_runtime_file "$src" "$dst" "$dst_dir" "$dst_dir_mode" "$mode" "$user" "$group" "$scope" "$tmp_manifest"
	done < <(jq -r '.stagedFiles[]? | [.src, .dst, .dstDir, (.dstDirMode // "0750"), (if has("mode") then (.mode // "null") else "none" end), (.user // "null"), (.group // "null"), (.scope // "host")] | @tsv' "$podman_compose_metadata")

	while IFS= read -r line; do
		[ -n "$line" ] || continue
		stage_secret_env_file "$line" "$tmp_manifest"
	done < <(jq -c '.envSecretFiles[]?' "$podman_compose_metadata")

	finalize_staged_dirs
	mv -f "$tmp_manifest" "$manifest_path"
}

verify_staged_file_entries() {
	local jq_filter label src dst scope failed=0
	jq_filter="$1"
	label="$2"
	while IFS=$'\t' read -r src dst scope; do
		[ -n "$src" ] || continue
		if ! run_scoped "$scope" test -f "$dst"; then
			printf '%s\n' "podman compose ${label} is missing: $dst" >&2
			failed=1
			continue
		fi
		if ! run_scoped "$scope" cmp -s -- "$src" "$dst"; then
			printf '%s\n' "podman compose ${label} drifted from source: $dst" >&2
			failed=1
		fi
	done < <(jq -r "$jq_filter" "$podman_compose_metadata")
	[ "$failed" -eq 0 ]
}

verify_staged_file_entries_present() {
	local jq_filter label src dst scope failed=0
	jq_filter="$1"
	label="$2"
	while IFS=$'\t' read -r src dst scope; do
		[ -n "$src" ] || continue
		if ! run_scoped "$scope" test -f "$dst"; then
			printf '%s\n' "podman compose ${label} is missing: $dst" >&2
			failed=1
		fi
	done < <(jq -r "$jq_filter" "$podman_compose_metadata")
	[ "$failed" -eq 0 ]
}

render_secret_env_file() {
	local secret_json env_name src
	secret_json="$1"

	while IFS=$'\t' read -r env_name src; do
		[ -n "$env_name" ] || continue
		{
			printf '%s=' "$env_name"
			tr -d '\n' <"$src"
			printf '\n'
		}
	done < <(jq -r '.entries[]? | [.name, .src] | @tsv' <<<"$secret_json")
}

verify_secret_env_files() {
	local secret_json dst scope failed=0
	while IFS= read -r secret_json; do
		[ -n "$secret_json" ] || continue
		dst="$(jq -r '.dst' <<<"$secret_json")"
		scope="$(jq -r '.scope // "host"' <<<"$secret_json")"
		if ! run_scoped "$scope" test -f "$dst"; then
			printf '%s\n' "podman compose generated env-secret file is missing: $dst" >&2
			failed=1
			continue
		fi
		if ! render_secret_env_file "$secret_json" | run_scoped "$scope" cmp -s - "$dst"; then
			printf '%s\n' "podman compose generated env-secret file drifted from source: $dst" >&2
			failed=1
		fi
	done < <(jq -c '.envSecretFiles[]?' "$podman_compose_metadata")
	[ "$failed" -eq 0 ]
}

verify_staged_runtime_files() {
	local failed=0
	verify_staged_file_entries '.stagedFiles[]? | [.src, .dst, (.scope // "host")] | @tsv' "staged file" || failed=1
	verify_staged_file_entries '.reload.stagedFiles[]? | [.src, .dst, (.scope // "host")] | @tsv' "reload staged file" || failed=1
	verify_secret_env_files || failed=1
	[ "$failed" -eq 0 ]
}

verify_staged_runtime_files_present() {
	local failed=0
	verify_staged_file_entries_present '.stagedFiles[]? | [.src, .dst, (.scope // "host")] | @tsv' "staged file" || failed=1
	verify_staged_file_entries_present '.reload.stagedFiles[]? | [.src, .dst, (.scope // "host")] | @tsv' "reload staged file" || failed=1
	while IFS=$'\t' read -r dst scope; do
		[ -n "$dst" ] || continue
		if ! run_scoped "$scope" test -f "$dst"; then
			printf '%s\n' "podman compose generated env-secret file is missing: $dst" >&2
			failed=1
		fi
	done < <(jq -r '.envSecretFiles[]? | [.dst, (.scope // "host")] | @tsv' "$podman_compose_metadata")
	[ "$failed" -eq 0 ]
}

path_in_file() {
	local path file
	path="$1"
	file="$2"
	[ -f "$file" ] && grep -Fxq -- "$path" "$file"
}

path_is_under_reload_dir() {
	local path dir
	path="$1"
	while IFS= read -r dir; do
		[ -n "$dir" ] || continue
		if [ "$path" = "$dir" ] || [[ "$path" == "$dir/"* ]]; then
			return 0
		fi
	done < <(jq -r '.reload.dirs[]?.dst' "$podman_compose_metadata")
	return 1
}

write_reload_manifest() {
	local old_manifest selected_manifest prune_stale merged_manifest path
	old_manifest="$1"
	selected_manifest="$2"
	prune_stale="$3"
	merged_manifest="${manifest_path}.tmp"

	remove_path_if_exists "$merged_manifest"
	: >"$merged_manifest"

	if [ -f "$old_manifest" ]; then
		while IFS= read -r path; do
			[ -n "$path" ] || continue
			if [ "$prune_stale" = "true" ] && path_is_under_reload_dir "$path" && ! path_in_file "$path" "$selected_manifest"; then
				continue
			fi
			printf '%s\n' "$path" >>"$merged_manifest"
		done <"$old_manifest"
	fi

	while IFS= read -r path; do
		[ -n "$path" ] || continue
		if ! path_in_file "$path" "$merged_manifest"; then
			printf '%s\n' "$path" >>"$merged_manifest"
		fi
	done <"$selected_manifest"

	mv -f "$merged_manifest" "$manifest_path"
}

cleanup_stale_reload_files() {
	local old_manifest selected_manifest path
	old_manifest="$1"
	selected_manifest="$2"

	if [ -f "$old_manifest" ]; then
		while IFS= read -r path; do
			[ -n "$path" ] || continue
			if path_is_under_reload_dir "$path" && ! path_in_file "$path" "$selected_manifest"; then
				if [ -e "$path" ] || [ -L "$path" ]; then
					rm -rf -- "$path"
				fi
			fi
		done <"$old_manifest"
	fi
}

prepare_reload_dirs_for_write() {
	local dst mode user group scope once
	while IFS=$'\t' read -r dst mode user group scope once; do
		[ -n "$dst" ] || continue
		prepare_staged_dir_for_write "$dst" "$mode" "$user" "$group" "$scope" "$once"
	done < <(jq -r '(.reload.dirs // [] | sort_by(.dst | length))[] | [.dst, (if has("mode") then (.mode // "null") else "0750" end), (.user // "null"), (.group // "null"), (.scope // "host"), (.once // false)] | @tsv' "$podman_compose_metadata")
}

finalize_reload_dirs() {
	local dst mode user group scope once
	while IFS=$'\t' read -r dst mode user group scope once; do
		[ -n "$dst" ] || continue
		if [ "$once" = "true" ]; then
			continue
		fi
		if [ ! -d "$dst" ] || [ -L "$dst" ]; then
			remove_path_if_exists "$dst"
			install -d -m 0700 "$dst"
		fi
		apply_perms "$dst" "$mode" "$user" "$group" "$scope"
	done < <(jq -r '(.reload.dirs // [] | sort_by(.dst | length) | reverse)[] | [.dst, (if has("mode") then (.mode // "null") else "0750" end), (.user // "null"), (.group // "null"), (.scope // "host"), (.once // false)] | @tsv' "$podman_compose_metadata")
}

stage_reload_files() {
	local old_manifest selected_manifest src dst dst_dir dst_dir_mode mode user group scope
	old_manifest="$1"
	selected_manifest="$2"

	if [ -f "$manifest_path" ]; then
		cp "$manifest_path" "$old_manifest"
	else
		: >"$old_manifest"
	fi
	: >"$selected_manifest"

	prepare_reload_dirs_for_write

	while IFS=$'\t' read -r src dst dst_dir dst_dir_mode mode user group scope; do
		[ -n "$src" ] || continue
		stage_runtime_file "$src" "$dst" "$dst_dir" "$dst_dir_mode" "$mode" "$user" "$group" "$scope" "$selected_manifest"
	done < <(jq -r '.reload.stagedFiles[]? | [.src, .dst, .dstDir, (.dstDirMode // "0750"), (if has("mode") then (.mode // "null") else "none" end), (.user // "null"), (.group // "null"), (.scope // "host")] | @tsv' "$podman_compose_metadata")

	finalize_reload_dirs
	write_reload_manifest "$old_manifest" "$selected_manifest" false
}

stage_secret_env_file() {
	local secret_json tmp_manifest dst dst_dir mode user group scope tmp_secret_env
	secret_json="$1"
	tmp_manifest="$2"
	IFS=$'\t' read -r dst dst_dir mode user group scope < <(
		jq -r '[.dst, .dstDir, (if has("mode") then (.mode // "null") else "0400" end), (.user // "null"), (.group // "null"), (.scope // "host")] | @tsv' <<<"$secret_json"
	)
	tmp_secret_env="${dst}.tmp"

	install -d -m 0700 "$dst_dir"
	remove_path_if_exists "$dst"
	remove_path_if_exists "$tmp_secret_env"
	render_secret_env_file "$secret_json" >"$tmp_secret_env"

	apply_perms "$tmp_secret_env" "$mode" "$user" "$group" "$scope"
	mv -f "$tmp_secret_env" "$dst"
	printf '%s\n' "$dst" >>"$tmp_manifest"
}

cleanup_runtime_files() {
	local path
	prepare_staged_dirs_for_write
	if [ -f "$manifest_path" ]; then
		while IFS= read -r path; do
			if [ -e "$path" ] || [ -L "$path" ]; then
				rm -rf -- "$path"
			fi
		done <"$manifest_path"
		rm -f "$manifest_path"
	fi
	finalize_staged_dirs
}

path_is_under_working_dir() {
	local path
	path="$1"
	[ "$path" != "$working_dir" ] && [[ "$path" == "$working_dir"/* ]]
}

cleanup_staged_dirs_under_working_dir() {
	local dst
	while IFS= read -r dst; do
		[ -n "$dst" ] || continue
		[ -e "$dst" ] || [ -L "$dst" ] || continue
		if ! path_is_under_working_dir "$dst"; then
			printf '%s\n' "refusing to remove managed staged dir outside workingDir during delete-all: $dst" >&2
			exit 1
		fi
		rm -rf -- "$dst"
	done < <(jq -r '(.stagedDirs // [] | sort_by(.dst | length) | reverse)[] | .dst' "$podman_compose_metadata")
}

current_stop_policy() {
	if [ -f "$state_path" ] && runtime_state_matches; then
		jq -r '.removalPolicy // "delete"' "$state_path" 2>/dev/null || printf '%s\n' "delete"
		return
	fi
	printf '%s\n' "delete"
}

unit_is_active_or_transitioning() {
	local active_state
	active_state="$(systemctl --user show --property=ActiveState --value "${podman_compose_service_name}.service" 2>/dev/null || true)"
	case "$active_state" in
	active | activating | deactivating | reloading)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

removal_has_no_staged_runtime() {
	[ ! -f "$manifest_path" ] || return 1
	unit_is_active_or_transitioning && return 1
	return 0
}

apply_compose_stop_policy() {
	local stop_policy
	stop_policy="$1"

	if [ ! -d "$working_dir" ]; then
		printf '%s\n' "podman compose working directory is absent; cannot stop safely: $working_dir" >&2
		return 1
	fi

	case "$stop_policy" in
	stop)
		compose_stop
		;;
	delete)
		compose_down
		;;
	delete-all)
		compose_down_volumes
		;;
	*)
		printf '%s\n' "unsupported podman compose stop policy: $stop_policy" >&2
		return 1
		;;
	esac
}

apply_compose_post_stop_policy() {
	local stop_policy
	stop_policy="$1"

	case "$stop_policy" in
	stop) ;;
	delete)
		cleanup_runtime_files
		;;
	delete-all)
		cleanup_runtime_files
		cleanup_staged_dirs_under_working_dir
		;;
	*)
		cleanup_runtime_files
		;;
	esac
	clear_removal_policy_marker
}

has_removal_policy_marker() {
	[ -f "$state_path" ] || return 1
	runtime_state_matches || return 1
	jq -e 'has("removalPolicy")' "$state_path" >/dev/null 2>&1
}

write_removal_policy_marker() {
	local tmp_state
	install -d -m 0750 "$generated_dir"
	tmp_state="${state_path}.tmp"
	existing_runtime_state_json |
		jq -c \
			--argjson version "$runtime_state_version" \
			--arg kind "$runtime_state_kind" \
			--arg adoptionStamp "$adoption_stamp" \
			--arg removalPolicy "$removal_policy" \
			'. + {version: $version, kind: $kind, adoptionStamp: $adoptionStamp, removalPolicy: $removalPolicy}' >"$tmp_state"
	chmod 0640 "$tmp_state"
	mv -f "$tmp_state" "$state_path"
}

clear_removal_policy_marker() {
	if [ ! -f "$state_path" ]; then
		return
	fi
	if ! runtime_state_matches; then
		rm -f "$state_path"
		return
	fi
	write_runtime_state_with_filter 'del(.removalPolicy)'
}

failing_states_report() {
	jq -r '
    map(
      select(
        (.State // "") as $state
        | ($state != "running")
        and (($state == "exited" and ((.ExitCode // 1) == 0)) | not)
      )
    )
    | .[]
    | "\((.Names // ["<unknown>"])[0]): state=\(.State // "unknown") exit=\(.ExitCode // "n/a") status=\(.Status // "")"
  '
}

expected_compose_services_json() {
	if [ "${#expected_compose_services[@]}" -eq 0 ]; then
		printf '%s\n' "[]"
		return
	fi
	printf '%s\n' "${expected_compose_services[@]}" | jq -R . | jq -s -c .
}

compose_up_no_progress_report() {
	local state_json failing_states missing_services expected_services_json
	state_json="$(cat)"
	failing_states="$(printf '%s' "$state_json" | failing_states_report)"
	expected_services_json="$(expected_compose_services_json)"
	missing_services="$(
		printf '%s' "$state_json" |
			jq -r --argjson expected "$expected_services_json" '
				def compose_service:
					.Labels["io.podman.compose.service"]
					// .Labels["com.docker.compose.service"]
					// empty;

				($expected - ([.[] | select((.State // "") == "running") | compose_service] | unique)) as $missing
				| if ($expected | length) == 0 or ($missing | length) == 0 then
					empty
				  elif length == 0 then
					"podman compose has no managed containers for expected services during start:",
					($missing[])
				  else
					"podman compose is missing running containers for expected services during start:",
					($missing[])
				  end
			'
	)"

	if [ -n "$failing_states" ]; then
		printf '%s\n' "$failing_states"
	fi
	if [ "$long_running" = "true" ] && [ -n "$missing_services" ]; then
		printf '%s\n' "$missing_services"
	fi
}

compose_state_json() {
	(
		close_lifecycle_fds_for_child
		cd /
		podman_no_notify_timeout "$compose_monitor_timeout_seconds" ps -a \
			--filter "label=com.docker.compose.project.working_dir=$working_dir" \
			--format json
	)
}

compose_up_no_progress_probe_interval_seconds() {
	local interval
	interval=5
	if [ "$compose_up_no_progress_seconds" -lt "$interval" ]; then
		interval="$compose_up_no_progress_seconds"
	fi
	[ "$interval" -gt 0 ] || interval=1
	printf '%s\n' "$interval"
}

json_string() {
	jq -Rn --arg value "$1" '$value'
}

compose_runtime_policy_override_file() {
	local override_file tmp_file service sep
	if [ "${#expected_compose_services[@]}" -eq 0 ]; then
		return 0
	fi
	install -d -m 0700 "$generated_dir"
	override_file="$generated_dir/runtime-policy.override.json"
	tmp_file="$(mktemp "${override_file}.tmp.XXXXXX")"
	{
		printf '{"services":{'
		sep=""
		for service in "${expected_compose_services[@]}"; do
			printf '%s%s:{"pull_policy":"never","restart":"no"}' "$sep" "$(json_string "$service")"
			sep=","
		done
		printf '}}\n'
	} >"$tmp_file"
	mv -f "$tmp_file" "$override_file"
	printf '%s\n' "$override_file"
}

compose_up_once_mutating() {
	local mode status=0
	mode="$1"
	case "$mode" in
	force)
		# Recreate drift is resolved before the provider starts. It never creates
		# a second Compose attempt.
		remove_compose_project_containers || status="$?"
		;;
	normal) ;;
	*)
		printf '%s\n' "unsupported podman compose start mode: $mode" >&2
		return 1
		;;
	esac
	if [ "$status" -eq 0 ]; then
		remove_conflicting_compose_container_names || status="$?"
	fi
	if [ "$status" -eq 0 ]; then
		compose_up_supervised || status="$?"
	fi
	return "$status"
}

compose_up() {
	local status=0
	begin_rootless_mutation "compose up"
	compose_up_once_mutating normal || status="$?"
	if [ "$status" -eq 0 ]; then
		commit_rootless_mutation
	else
		rollback_failed_compose_start "$status"
	fi
	return "$status"
}

compose_up_force_recreate() {
	local status=0
	begin_rootless_mutation "compose up pre-clean recreate"
	compose_up_once_mutating force || status="$?"
	if [ "$status" -eq 0 ]; then
		commit_rootless_mutation
	else
		rollback_failed_compose_start "$status"
	fi
	return "$status"
}

compose_up_fatal_line() {
	local line
	line="$1"
	grep -Eq \
		'exceeded num_locks|container name ".*" is already in use|cannot be used as a dependency|rootlessport listen tcp .* bind:|aardvark-dns failed to start|failed to bind udp listener .*:53|(^|[[:space:]])image pull-error[[:space:]]' \
		<<<"$line"
}

compose_pull_fatal_line() {
	local line
	line="$1"
	grep -Eq \
		'(^|[[:space:]])image pull-error[[:space:]]|^Error: unable to copy from source docker://' \
		<<<"$line"
}

positive_integer_or_default() {
	local value default
	value="$1"
	default="$2"

	if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$default"
	fi
}

nonnegative_integer_or_default() {
	local value default
	value="$1"
	default="$2"

	if [[ "$value" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$value"
	else
		printf '%s\n' "$default"
	fi
}

parse_systemd_timespan_seconds() {
	local value token number unit total=0
	value="$1"

	case "$value" in
	"" | infinity)
		printf '%s\n' 0
		return 0
		;;
	esac

	for token in $value; do
		if [[ "$token" =~ ^([0-9]+)([a-zA-Z]+)$ ]]; then
			number="${BASH_REMATCH[1]}"
			unit="${BASH_REMATCH[2]}"
		elif [[ "$token" =~ ^([0-9]+)$ ]]; then
			number="${BASH_REMATCH[1]}"
			unit="s"
		else
			continue
		fi

		case "$unit" in
		us | usec)
			[ "$number" -gt 0 ] && total=$((total + 1))
			;;
		ms | msec)
			total=$((total + (number + 999) / 1000))
			;;
		s | sec)
			total=$((total + number))
			;;
		min)
			total=$((total + number * 60))
			;;
		h | hr)
			total=$((total + number * 3600))
			;;
		d | day)
			total=$((total + number * 86400))
			;;
		esac
	done

	printf '%s\n' "$total"
}

compose_unit_timeout_seconds() {
	local unit property default_seconds timeout_value timeout_seconds
	unit="$1"
	property="$2"
	default_seconds="$3"
	timeout_value="$(systemctl --user show --property="$property" --value "$unit" 2>/dev/null || true)"
	case "$timeout_value" in
	infinity)
		printf '%s\n' 0
		return 0
		;;
	esac
	timeout_seconds="$(parse_systemd_timespan_seconds "$timeout_value")"
	if [ "$timeout_seconds" -le 0 ]; then
		timeout_seconds="$default_seconds"
	fi
	printf '%s\n' "$timeout_seconds"
}

compose_start_timeout_seconds() {
	if [[ "$compose_provider_timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
		printf '%s\n' "$compose_provider_timeout_seconds"
		return 0
	fi
	compose_unit_timeout_seconds "${compose_start_timeout_unit:-${podman_compose_service_name}.service}" TimeoutStartUSec "$compose_start_default_timeout_seconds"
}

compose_stop_timeout_seconds() {
	local timeout_seconds
	timeout_seconds="$(compose_unit_timeout_seconds "${podman_compose_service_name}.service" TimeoutStopUSec "$compose_stop_default_timeout_seconds")"
	if [ "$timeout_seconds" -gt "$compose_stop_default_timeout_seconds" ]; then
		timeout_seconds="$compose_stop_default_timeout_seconds"
	fi
	printf '%s\n' "$timeout_seconds"
}

compose_cleanup_reserve_seconds() {
	local timeout_seconds reserve_seconds
	timeout_seconds="$1"
	reserve_seconds="$((timeout_seconds / 10))"
	if [ "$reserve_seconds" -lt 5 ]; then
		reserve_seconds=5
	fi
	if [ "$reserve_seconds" -gt 30 ]; then
		reserve_seconds=30
	fi
	if [ "$timeout_seconds" -le "$((reserve_seconds + 1))" ]; then
		reserve_seconds=1
	fi
	printf '%s\n' "$reserve_seconds"
}

supervised_pid_file() {
	mktemp "${TMPDIR:-/tmp}/podman-compose-supervised.XXXXXX"
}

supervised_child_pid() {
	local fallback_pid pid_file child_pid
	fallback_pid="$1"
	pid_file="$2"

	if [ -s "$pid_file" ] && read -r child_pid <"$pid_file"; then
		case "$child_pid" in
		"" | *[!0-9]*)
			printf '%s\n' "$fallback_pid"
			;;
		*)
			printf '%s\n' "$child_pid"
			;;
		esac
	else
		printf '%s\n' "$fallback_pid"
	fi
}

process_group_id_for_pid() {
	local pid
	pid="$1"
	ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]'
}

current_process_group_id() {
	ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]'
}

process_group_member_pids() {
	local pgid
	pgid="$1"
	ps -eo pid=,pgid= |
		awk -v pgid="$pgid" '$2 == pgid { print $1 }'
}

process_group_has_members() {
	local pgid
	pgid="$1"
	[ -n "$(process_group_member_pids "$pgid")" ]
}

wait_for_compose_process_group_exit() {
	local pid pgid timeout_seconds started_at now member_pids
	pid="$1"
	pgid="$2"
	timeout_seconds="$3"
	started_at="$(now_epoch)"

	while true; do
		if [ -n "$pgid" ]; then
			if ! process_group_has_members "$pgid"; then
				return 0
			fi
		elif ! kill -0 "$pid" 2>/dev/null; then
			return 0
		fi

		now="$(now_epoch)"
		if [ "$now" -ge "$((started_at + timeout_seconds))" ]; then
			if [ -n "$pgid" ]; then
				member_pids="$(process_group_member_pids "$pgid" | paste -sd ' ' -)"
				printf '%s\n' "podman compose process group $pgid still has live members after ${timeout_seconds}s: ${member_pids:-<unknown>}" >&2
			else
				printf '%s\n' "podman compose process $pid still alive after ${timeout_seconds}s" >&2
			fi
			return 1
		fi

		sleep 0.2
	done
}

terminate_compose_process() {
	local pid pgid own_pgid
	pid="$1"
	pgid="$(process_group_id_for_pid "$pid")"
	own_pgid="$(current_process_group_id)"
	if [ -n "$pgid" ] && [ "$pgid" = "$own_pgid" ]; then
		printf '%s\n' "refusing to signal caller process group $pgid while terminating podman compose pid $pid; falling back to direct pid signal" >&2
		pgid=""
	fi

	if [ -n "$pgid" ]; then
		kill -- "-$pgid" 2>/dev/null || true
	else
		kill "$pid" 2>/dev/null || true
	fi
	wait_for_compose_process_group_exit "$pid" "$pgid" 3 && return 0

	if [ -n "$pgid" ]; then
		kill -KILL -- "-$pgid" 2>/dev/null || true
	else
		kill -KILL "$pid" 2>/dev/null || true
	fi
	wait_for_compose_process_group_exit "$pid" "$pgid" 5 || true
}

cleanup_active_supervised_compose() {
	local child_pid

	if [ -n "$supervised_active_pid" ] && kill -0 "$supervised_active_pid" 2>/dev/null; then
		child_pid="$(supervised_child_pid "$supervised_active_pid" "$supervised_active_pid_file")"
		terminate_compose_process "$child_pid"
		wait "$supervised_active_pid" 2>/dev/null || true
	fi
	rm -f -- "$supervised_active_pid_file"
	supervised_active_pid=""
	supervised_active_pid_file=""
}

set_active_supervised_compose() {
	supervised_active_pid="$1"
	supervised_active_pid_file="$2"
	trap cleanup_active_supervised_compose INT TERM
}

clear_active_supervised_compose() {
	trap - INT TERM
	rm -f -- "$supervised_active_pid_file"
	supervised_active_pid=""
	supervised_active_pid_file=""
}

compose_command_supervised() {
	local label timeout_seconds reserve_seconds deadline_seconds started_at now line timeout_seen=0 status=0
	local compose_output_fd compose_pid compose_child_pid compose_pid_file
	label="$1"
	timeout_seconds="$2"
	shift 2

	started_at="$(now_epoch)"
	reserve_seconds=0
	deadline_seconds=0
	if [ "$timeout_seconds" -gt 0 ]; then
		reserve_seconds="$(compose_cleanup_reserve_seconds "$timeout_seconds")"
		deadline_seconds="$((started_at + timeout_seconds - reserve_seconds))"
	fi
	compose_pid_file="$(supervised_pid_file)"

	coproc COMPOSE_CMD_PROC {
		(
			close_lifecycle_fds_for_child
			cd "$working_dir"
			# shellcheck disable=SC2016
			exec setsid bash -c \
				'printf "%s\n" "$$" > "$1"; shift; exec "$@"' \
				bash "$compose_pid_file" env -u NOTIFY_SOCKET -u WATCHDOG_PID -u WATCHDOG_USEC "$@"
		) 2>&1
	}
	compose_pid="$COMPOSE_CMD_PROC_PID"
	compose_output_fd="${COMPOSE_CMD_PROC[0]}"
	set_active_supervised_compose "$compose_pid" "$compose_pid_file"

	while true; do
		if IFS= read -r -t 1 -u "$compose_output_fd" line 2>/dev/null; then
			printf '%s\n' "$line"
			continue
		fi

		now="$(now_epoch)"
		if [ "$timeout_seconds" -gt 0 ] && [ "$now" -ge "$deadline_seconds" ]; then
			printf '%s\n' "podman compose ${label} exceeded helper deadline for ${podman_compose_service_name}; reserving ${reserve_seconds}s for cleanup before systemd timeout" >&2
			compose_child_pid="$(supervised_child_pid "$compose_pid" "$compose_pid_file")"
			terminate_compose_process "$compose_child_pid"
			timeout_seen=1
			break
		fi

		if ! kill -0 "$compose_pid" 2>/dev/null; then
			break
		fi
	done

	while IFS= read -r -t 0.1 -u "$compose_output_fd" line 2>/dev/null; do
		printf '%s\n' "$line"
	done

	wait "$compose_pid" || status="$?"
	exec {compose_output_fd}<&- 2>/dev/null || true
	clear_active_supervised_compose

	if [ "$timeout_seen" -eq 1 ]; then
		return 1
	fi
	return "$status"
}

compose_up_supervised() {
	local timeout_seconds reserve_seconds deadline_seconds started_at now line fatal_seen=0 status=0 fatal_status dns_status
	local compose_output_fd compose_up_pid compose_up_child_pid compose_up_pid_file
	local state_probe_interval last_state_probe=0 no_progress_since=0 state_json no_progress_report elapsed_no_progress terminal_failures
	local runtime_policy_override=""
	local -a local_compose_file_args=() up_args=()
	compose_up_project_dns_reload_attempted=0
	load_compose_dns_dependencies
	fatal_status="$compose_start_stuck_exit_status"
	timeout_seconds="$(compose_start_timeout_seconds)"
	started_at="$(now_epoch)"
	reserve_seconds=0
	deadline_seconds=0
	if [ "$timeout_seconds" -gt 0 ]; then
		reserve_seconds="$(compose_cleanup_reserve_seconds "$timeout_seconds")"
		deadline_seconds="$((started_at + timeout_seconds - reserve_seconds))"
	fi
	state_probe_interval="$(compose_up_no_progress_probe_interval_seconds)"

	local_compose_file_args=("${compose_file_args[@]}")
	runtime_policy_override="$(compose_runtime_policy_override_file)"
	if [ -n "$runtime_policy_override" ]; then
		local_compose_file_args+=(-f "$runtime_policy_override")
	fi
	up_args=(podman compose "${podman_compose_base_args[@]}" "${compose_args[@]}" "${local_compose_file_args[@]}" up --no-build -d --remove-orphans)
	compose_up_pid_file="$(supervised_pid_file)"

	coproc COMPOSE_UP_PROC {
		(
			close_lifecycle_fds_for_child
			cd "$working_dir"
			# shellcheck disable=SC2016
			exec setsid bash -c \
				'printf "%s\n" "$$" > "$1"; shift; exec "$@"' \
				bash "$compose_up_pid_file" env -u NOTIFY_SOCKET -u WATCHDOG_PID -u WATCHDOG_USEC "${up_args[@]}"
		) 2>&1
	}
	compose_up_pid="$COMPOSE_UP_PROC_PID"
	compose_output_fd="${COMPOSE_UP_PROC[0]}"
	set_active_supervised_compose "$compose_up_pid" "$compose_up_pid_file"

	while true; do
		if IFS= read -r -t 1 -u "$compose_output_fd" line 2>/dev/null; then
			printf '%s\n' "$line"
			if compose_up_fatal_line "$line"; then
				fatal_seen=1
				printf '%s\n' "podman compose start hit fatal output for ${podman_compose_service_name}; terminating early" >&2
				compose_up_child_pid="$(supervised_child_pid "$compose_up_pid" "$compose_up_pid_file")"
				terminate_compose_process "$compose_up_child_pid"
				fatal_status="$compose_start_stuck_exit_status"
				break
			fi
			continue
		fi

		now="$(now_epoch)"
		if [ "$timeout_seconds" -gt 0 ] && [ "$now" -ge "$deadline_seconds" ]; then
			printf '%s\n' "podman compose start exceeded helper deadline for ${podman_compose_service_name}; reserving ${reserve_seconds}s for cleanup before systemd timeout" >&2
			compose_up_child_pid="$(supervised_child_pid "$compose_up_pid" "$compose_up_pid_file")"
			terminate_compose_process "$compose_up_child_pid"
			fatal_seen=1
			fatal_status="$compose_start_stuck_exit_status"
			break
		fi
		if ! kill -0 "$compose_up_pid" 2>/dev/null; then
			break
		fi
		if [ "$long_running" = "true" ] && [ "$compose_up_no_progress_seconds" -gt 0 ] &&
			[ "$now" -ge "$((last_state_probe + state_probe_interval))" ]; then
			last_state_probe="$now"
			if state_json="$(compose_state_json 2>/dev/null)"; then
				terminal_failures="$(printf '%s' "$state_json" | compose_state_terminal_failure_report)"
				if [ -n "$terminal_failures" ]; then
					printf '%s\n' "podman compose reached a terminal container state while starting ${podman_compose_service_name}:" >&2
					printf '%s\n' "$terminal_failures" >&2
					compose_up_child_pid="$(supervised_child_pid "$compose_up_pid" "$compose_up_pid_file")"
					terminate_compose_process "$compose_up_child_pid"
					fatal_seen=1
					break
				fi
				if printf '%s' "$state_json" | compose_state_has_pending_health; then
					dns_status=0
					if verify_compose_dns; then
						dns_status=0
					else
						dns_status="$?"
					fi
					if [ "$dns_status" -eq 1 ] &&
						[ "$compose_up_project_dns_reload_attempted" -eq 0 ]; then
						compose_up_project_dns_reload_attempted=1
						mark_compose_dns_correction_attempted
						printf '%s\n' \
							"podman compose health-starting state has direct peer-service DNS evidence for ${podman_compose_service_name};" \
							"reloading running project networks once in place" >&2
						if reload_compose_project_networks_mutating; then
							no_progress_since=0
							continue
						fi
						printf '%s\n' "podman compose in-place project network reload failed for ${podman_compose_service_name}; terminating start" >&2
						compose_up_child_pid="$(supervised_child_pid "$compose_up_pid" "$compose_up_pid_file")"
						terminate_compose_process "$compose_up_child_pid"
						fatal_seen=1
						break
					fi
					# A declared healthcheck start period is active progress. The unit's
					# TimeoutStartSec remains the outer bound for health convergence.
					no_progress_since=0
					continue
				fi
				no_progress_report="$(printf '%s' "$state_json" | compose_up_no_progress_report)"
				if [ -n "$no_progress_report" ]; then
					if [ "$no_progress_since" -eq 0 ]; then
						no_progress_since="$now"
					fi
					elapsed_no_progress="$((now - no_progress_since))"
					if [ "$elapsed_no_progress" -ge "$compose_up_no_progress_seconds" ]; then
						printf '%s\n' "podman compose start made no healthy state progress for ${elapsed_no_progress}s; terminating ${podman_compose_service_name}" >&2
						printf '%s\n' "$no_progress_report" >&2
						compose_up_child_pid="$(supervised_child_pid "$compose_up_pid" "$compose_up_pid_file")"
						terminate_compose_process "$compose_up_child_pid"
						fatal_seen=1
						break
					fi
				else
					no_progress_since=0
				fi
			fi
		fi
	done

	while IFS= read -r -t 0.1 -u "$compose_output_fd" line 2>/dev/null; do
		printf '%s\n' "$line"
	done

	wait "$compose_up_pid" || status="$?"
	exec {compose_output_fd}<&- 2>/dev/null || true
	clear_active_supervised_compose

	if [ "$fatal_seen" -eq 1 ]; then
		return "$fatal_status"
	fi
	if [ "$status" -eq 125 ]; then
		printf '%s\n' "podman compose returned runtime status 125 for ${podman_compose_service_name}; failing the single provider attempt" >&2
	fi
	return "$status"
}

compose_down() {
	local container volume status=0 containers=() anonymous_volumes=()

	while IFS= read -r container; do
		[ -n "$container" ] || continue
		containers+=("$container")
	done < <(compose_project_container_targets)

	while IFS= read -r volume; do
		[ -n "$volume" ] || continue
		anonymous_volumes+=("$volume")
	done < <(anonymous_volume_names_for_containers "${containers[@]}")

	compose_command_supervised down "$(compose_stop_timeout_seconds)" podman compose "${podman_compose_base_args[@]}" "${compose_args[@]}" "${compose_file_args[@]}" down || status="$?"
	for volume in "${anonymous_volumes[@]}"; do
		remove_anonymous_volume_target "$volume" || status=1
	done
	return "$status"
}

compose_project_container_ids() {
	(
		close_lifecycle_fds_for_child
		cd /
		podman_no_notify_timeout "$compose_monitor_timeout_seconds" ps -a \
			--filter "label=com.docker.compose.project.working_dir=$working_dir" \
			--format '{{.ID}}'
	)
}

expected_compose_project_container_names() {
	local compose_project compose_service
	compose_project="$(basename "$working_dir")"
	for compose_service in "${expected_compose_services[@]}"; do
		[ -n "$compose_service" ] || continue
		printf '%s\n' "${compose_project}_${compose_service}_1"
	done
}

compose_project_container_names() {
	local compose_project
	compose_project="$(basename "$working_dir")"
	expected_compose_project_container_names
	if [ "${#expected_compose_services[@]}" -gt 0 ]; then
		return
	fi
	[ -f "$start_in_progress_path" ] || return
	while IFS= read -r compose_service; do
		[ -n "$compose_service" ] || continue
		printf '%s\n' "$compose_service"
	done < <(compose_project_storage_container_names "$compose_project")
}

compose_project_storage_container_names() {
	local compose_project storage_name
	compose_project="$1"
	while IFS= read -r storage_name; do
		[ -n "$storage_name" ] || continue
		case "$storage_name" in
		"${compose_project}"_*_1) printf '%s\n' "$storage_name" ;;
		esac
	done < <(
		podman_no_notify container list --all --storage --format '{{.Names}}' 2>/dev/null || true
	)
}

compose_project_container_targets() {
	{
		compose_project_container_ids
		compose_project_container_names
	} | awk 'NF && !seen[$0]++'
}

container_compose_working_dir_label() {
	local container
	container="$1"
	podman_no_notify inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container" 2>/dev/null || true
}

remove_conflicting_compose_container_names() {
	local container label
	local -a conflicting_containers=()

	while IFS= read -r container; do
		[ -n "$container" ] || continue
		if ! podman_no_notify container exists "$container"; then
			conflicting_containers+=("$container")
			continue
		fi
		label="$(container_compose_working_dir_label "$container")"
		if [ "$label" = "$working_dir" ]; then
			continue
		fi
		printf '%s\n' "removing conflicting podman compose container name for ${podman_compose_service_name}: ${container}"
		conflicting_containers+=("$container")
	done < <(compose_project_container_names)

	remove_container_targets_and_anonymous_volumes "${conflicting_containers[@]}"
}

container_state_json() {
	local container
	container="$1"
	(
		close_lifecycle_fds_for_child
		cd /
		podman_no_notify inspect --format '{{json .State}}' "$container"
	)
}

is_positive_integer() {
	case "${1-}" in
	"" | *[!0-9]*)
		return 1
		;;
	0)
		return 1
		;;
	*)
		return 0
		;;
	esac
}

running_container_pid_missing() {
	local container state_json running pid conmon_pid has_conmon_pid
	container="$1"

	if ! state_json="$(container_state_json "$container" 2>/dev/null)"; then
		printf '%s\n' "podman compose container $container was listed but cannot be inspected; forcing recreate for ${podman_compose_service_name}" >&2
		return 0
	fi

	if ! running="$(jq -r '.Running // false' <<<"$state_json")"; then
		printf '%s\n' "podman compose container $container has unreadable inspect state; forcing recreate for ${podman_compose_service_name}" >&2
		return 0
	fi
	[ "$running" = "true" ] || return 1

	if ! pid="$(jq -r '.Pid // 0' <<<"$state_json")"; then
		printf '%s\n' "podman compose container $container has unreadable runtime pid; forcing recreate for ${podman_compose_service_name}" >&2
		return 0
	fi
	if ! is_positive_integer "$pid" || [ ! -d "/proc/$pid" ]; then
		printf '%s\n' "podman compose container $container is marked running but runtime pid $pid is not present; forcing recreate for ${podman_compose_service_name}" >&2
		return 0
	fi

	if ! has_conmon_pid="$(jq -r 'has("ConmonPid")' <<<"$state_json")"; then
		printf '%s\n' "podman compose container $container has unreadable conmon pid state; forcing recreate for ${podman_compose_service_name}" >&2
		return 0
	fi
	if [ "$has_conmon_pid" = "true" ]; then
		if ! conmon_pid="$(jq -r '.ConmonPid // 0' <<<"$state_json")"; then
			printf '%s\n' "podman compose container $container has unreadable conmon pid; forcing recreate for ${podman_compose_service_name}" >&2
			return 0
		fi
		if ! is_positive_integer "$conmon_pid" || [ ! -d "/proc/$conmon_pid" ]; then
			printf '%s\n' "podman compose container $container is marked running but conmon pid $conmon_pid is not present; forcing recreate for ${podman_compose_service_name}" >&2
			return 0
		fi
	fi

	return 1
}

compose_running_container_pids_missing() {
	local container found_stale=1

	while IFS= read -r container; do
		[ -n "$container" ] || continue
		if running_container_pid_missing "$container"; then
			found_stale=0
		fi
	done < <(compose_project_container_ids)

	return "$found_stale"
}

compose_project_has_failed_containers() {
	local state_json failing_states

	[ "$long_running" = "true" ] || return 1
	if ! state_json="$(compose_state_json 2>/dev/null)"; then
		return 1
	fi
	failing_states="$(printf '%s' "$state_json" | failing_states_report)"
	[ -n "$failing_states" ] || return 1

	printf '%s\n' "podman compose project has non-running containers before start; forcing recreate for ${podman_compose_service_name}" >&2
	printf '%s\n' "$failing_states" >&2
	return 0
}

storage_container_exists_target() {
	local target name
	target="$1"

	while IFS= read -r name; do
		[ -n "$name" ] || continue
		[ "$name" = "$target" ] && return 0
	done < <(
		podman_no_notify container list --all --storage --format '{{.Names}}' 2>/dev/null || true
	)

	return 1
}

storage_mountpoint_from_remove_error() {
	local error
	error="$1"

	sed -n 's/.*replacing mount point "\([^"]*\)": directory not empty.*/\1/p' <<<"$error" | head -n 1
}

cleanup_stale_storage_mountpoint_contents() {
	local mountpoint storage_root
	mountpoint="$1"
	storage_root="${HOME:-}/.local/share/containers/storage"

	[ -n "${HOME:-}" ] || return 1
	case "$mountpoint" in
	"$storage_root"/overlay/*/merged) ;;
	*)
		printf '%s\n' "refusing to clean unexpected podman storage mountpoint: $mountpoint" >&2
		return 1
		;;
	esac
	[ -d "$mountpoint" ] || return 1
	if mountpoint -q "$mountpoint"; then
		printf '%s\n' "refusing to clean mounted podman storage mountpoint: $mountpoint" >&2
		return 1
	fi

	find "$mountpoint" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

remove_storage_container_target() {
	local target storage_error mountpoint
	target="$1"

	if storage_error="$(podman_no_notify rm --storage --force "$target" 2>&1)"; then
		[ -n "$storage_error" ] && printf '%s\n' "$storage_error"
		return 0
	fi
	case "$storage_error" in
	*"no such container"* | *"no container with ID or name"*) return 0 ;;
	esac

	mountpoint="$(storage_mountpoint_from_remove_error "$storage_error")"
	if [ -n "$mountpoint" ] && cleanup_stale_storage_mountpoint_contents "$mountpoint"; then
		if storage_error="$(podman_no_notify rm --storage --force "$target" 2>&1)"; then
			[ -n "$storage_error" ] && printf '%s\n' "$storage_error"
			return 0
		fi
		case "$storage_error" in
		*"no such container"* | *"no container with ID or name"*) return 0 ;;
		esac
	fi

	[ -n "$storage_error" ] && printf '%s\n' "$storage_error" >&2
	if storage_container_exists_target "$target"; then
		printf '%s\n' "podman storage container $target still exists for ${podman_compose_service_name}" >&2
		return 1
	fi
	return 0
}

remove_container_target() {
	local target remove_error cleanup_error storage_error unmount_error
	target="$1"
	if remove_error="$(podman_no_notify rm -f --depend -v "$target" 2>&1)"; then
		[ -n "$remove_error" ] && printf '%s\n' "$remove_error"
		if ! podman_no_notify container exists "$target"; then
			return 0
		fi
		if cleanup_error="$(podman_no_notify container cleanup --rm "$target" 2>&1)"; then
			[ -n "$cleanup_error" ] && printf '%s\n' "$cleanup_error"
			if ! podman_no_notify container exists "$target"; then
				return 0
			fi
		else
			case "$cleanup_error" in
			*"no such container"* | *"no container with name or ID"*) return 0 ;;
			*) [ -n "$cleanup_error" ] && printf '%s\n' "$cleanup_error" >&2 ;;
			esac
		fi
		printf '%s\n' "podman container $target still exists after removal for ${podman_compose_service_name}" >&2
		return 1
	fi
	case "$remove_error" in
	*"is mounted and cannot be removed"* | *"container state improper"*)
		if unmount_error="$(podman_no_notify unmount --force "$target" 2>&1)"; then
			[ -n "$unmount_error" ] && printf '%s\n' "$unmount_error"
			if remove_error="$(podman_no_notify rm -f --depend -v "$target" 2>&1)"; then
				[ -n "$remove_error" ] && printf '%s\n' "$remove_error"
				if ! podman_no_notify container exists "$target"; then
					return 0
				fi
				if cleanup_error="$(podman_no_notify container cleanup --rm "$target" 2>&1)"; then
					[ -n "$cleanup_error" ] && printf '%s\n' "$cleanup_error"
					if ! podman_no_notify container exists "$target"; then
						return 0
					fi
				else
					case "$cleanup_error" in
					*"no such container"* | *"no container with name or ID"*) return 0 ;;
					*) [ -n "$cleanup_error" ] && printf '%s\n' "$cleanup_error" >&2 ;;
					esac
				fi
				printf '%s\n' \
					"podman container $target still exists after forced unmount removal for ${podman_compose_service_name}" >&2
				return 1
			fi
		else
			case "$unmount_error" in
			*"no such container"* | *"no container with name or ID"*) ;;
			*) [ -n "$unmount_error" ] && printf '%s\n' "$unmount_error" >&2 ;;
			esac
		fi
		;;
	esac
	case "$remove_error" in
	*"no such container"* | *"no container with name or ID"*)
		remove_storage_container_target "$target"
		return "$?"
		;;
	esac
	if remove_storage_container_target "$target"; then
		return 0
	fi
	if cleanup_error="$(podman_no_notify container cleanup --rm "$target" 2>&1)"; then
		[ -n "$cleanup_error" ] && printf '%s\n' "$cleanup_error"
		if ! podman_no_notify container exists "$target" && ! storage_container_exists_target "$target"; then
			return 0
		fi
		printf '%s\n' "podman container $target still exists after cleanup for ${podman_compose_service_name}" >&2
		return 1
	fi
	case "$cleanup_error" in
	*"no such container"* | *"no container with name or ID"*)
		return 0
		;;
	esac
	printf '%s\n' "$remove_error" >&2
	[ -n "$cleanup_error" ] && printf '%s\n' "$cleanup_error" >&2
	return 1
}

is_anonymous_volume_name() {
	local volume_name
	volume_name="$1"
	[ "${#volume_name}" -eq 64 ] || return 1
	case "$volume_name" in
	*[!0-9a-f]*)
		return 1
		;;
	*)
		return 0
		;;
	esac
}

container_anonymous_volume_names() {
	local target mounts volume
	target="$1"

	if ! mounts="$(podman_no_notify inspect "$target" --format '{{json .Mounts}}' 2>/dev/null)"; then
		return 0
	fi

	while IFS= read -r volume; do
		[ -n "$volume" ] || continue
		is_anonymous_volume_name "$volume" || continue
		printf '%s\n' "$volume"
	done < <(jq -r '.[]? | select(.Type == "volume") | .Name // empty' <<<"$mounts" 2>/dev/null || true)
}

anonymous_volume_names_for_containers() {
	local container

	for container in "$@"; do
		container_anonymous_volume_names "$container"
	done | awk 'NF && !seen[$0]++'
}

remove_anonymous_volume_target() {
	local target remove_error
	target="$1"
	if remove_error="$(podman_no_notify volume rm "$target" 2>&1)"; then
		[ -n "$remove_error" ] && printf '%s\n' "$remove_error"
		return 0
	fi
	case "$remove_error" in
	*"no such volume"* | *"volume not known"* | *"is being used"*)
		[ -n "$remove_error" ] && printf '%s\n' "$remove_error" >&2
		return 0
		;;
	esac
	printf '%s\n' "$remove_error" >&2
	return 1
}

remove_container_targets_and_anonymous_volumes() {
	local container volume failed=0 anonymous_volumes=()
	local -a containers=("$@")

	[ "${#containers[@]}" -gt 0 ] || return 0
	while IFS= read -r volume; do
		[ -n "$volume" ] || continue
		anonymous_volumes+=("$volume")
	done < <(anonymous_volume_names_for_containers "${containers[@]}")
	for container in "${containers[@]}"; do
		remove_container_target "$container" || failed=1
	done
	for volume in "${anonymous_volumes[@]}"; do
		remove_anonymous_volume_target "$volume" || failed=1
	done
	return "$failed"
}

remove_compose_project_containers() {
	local container containers=()

	while IFS= read -r container; do
		[ -n "$container" ] || continue
		containers+=("$container")
	done < <(compose_project_container_targets)

	[ "${#containers[@]}" -gt 0 ] || return 0
	printf '%s\n' "removing stale podman compose containers for ${podman_compose_service_name}"
	(
		close_lifecycle_fds_for_child
		remove_container_targets_and_anonymous_volumes "${containers[@]}"
	)
}

cleanup_failed_compose_start() {
	printf '%s\n' "podman compose start failed for ${podman_compose_service_name}; cleaning project containers after failed attempt" >&2
	if ! compose_down; then
		printf '%s\n' "podman compose down after failed start failed for ${podman_compose_service_name}; attempting direct container removal" >&2
	fi
	if ! remove_compose_project_containers; then
		printf '%s\n' "direct removal of failed podman compose containers also failed for ${podman_compose_service_name}" >&2
	fi
}

rollback_failed_compose_start() {
	local original_status
	original_status="$1"
	cleanup_failed_compose_start
	if runtime_preflight_project_cleanup_complete; then
		if [ -n "$failed_start_cleanup_complete_path" ]; then
			install -d -m 0750 "${failed_start_cleanup_complete_path%/*}"
			: >"$failed_start_cleanup_complete_path"
		fi
		rollback_rootless_mutation_clean
	else
		leave_rootless_runtime_dirty "failed Compose start status ${original_status}; rollback postcondition was indeterminate"
	fi
}

cleanup_failed_compose_stop() {
	local stop_policy
	stop_policy="$1"

	case "$stop_policy" in
	delete | delete-all) ;;
	*)
		return 0
		;;
	esac

	printf '%s\n' "podman compose stop failed for ${podman_compose_service_name}; cleaning project containers"
	if ! remove_compose_project_containers; then
		printf '%s\n' "direct removal of stopped podman compose containers failed for ${podman_compose_service_name}" >&2
		return 1
	fi
}

failed_compose_stop_cleanup_satisfies_stop() {
	local stop_policy
	stop_policy="$1"

	case "$stop_policy" in
	delete | delete-all)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

compose_stop_postcondition_complete() {
	local active_states state_json
	if ! state_json="$(compose_state_json)"; then
		printf '%s\n' "cannot verify stopped podman project state for ${podman_compose_service_name}" >&2
		return 1
	fi
	active_states="$(
		jq -r '
			.[]
			| select((.State // "unknown") | IN("running", "paused", "restarting", "stopping", "unknown"))
			| "\((.Names // ["<unknown>"])[0]): state=\(.State // "unknown") status=\(.Status // "")"
		' <<<"$state_json"
	)"
	if [ -n "$active_states" ]; then
		printf '%s\n' "podman project still has active containers after stop for ${podman_compose_service_name}:" >&2
		printf '%s\n' "$active_states" >&2
		return 1
	fi
}

stop_policy_postcondition_complete() {
	case "$1" in
	stop)
		compose_stop_postcondition_complete
		;;
	delete | delete-all)
		runtime_preflight_project_cleanup_complete
		;;
	*)
		return 1
		;;
	esac
}

finish_stop_mutation() {
	local outcome reason stop_policy
	stop_policy="$1"
	reason="$2"
	outcome="${3:-commit}"
	if stop_policy_postcondition_complete "$stop_policy"; then
		case "$outcome" in
		commit) commit_rootless_mutation ;;
		rollback) rollback_rootless_mutation_clean ;;
		*) return 1 ;;
		esac
		return 0
	fi
	leave_rootless_runtime_dirty "$reason"
	return 1
}

post_stop_should_cleanup_failed_stop() {
	local stop_policy
	stop_policy="$1"

	[ -f "$stop_in_progress_path" ] || return 1
	case "${SERVICE_RESULT-}" in
	"" | success)
		return 1
		;;
	esac
	case "$stop_policy" in
	delete | delete-all)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

mark_start_in_progress_pid() {
	local pid
	pid="${1:-$$}"
	install -d -m 0750 "$generated_dir"
	{
		printf 'pid=%s\n' "$pid"
		printf 'startedAt=%s\n' "$(now_epoch)"
	} >"${start_in_progress_path}.tmp"
	mv -f "${start_in_progress_path}.tmp" "$start_in_progress_path"
}

mark_start_in_progress() {
	mark_start_in_progress_pid "$@"
}

clear_start_in_progress() {
	rm -f -- "$start_in_progress_path" "${start_in_progress_path}.tmp"
}

start_in_progress_pid() {
	[ -f "$start_in_progress_path" ] || return 1
	sed -n 's/^pid=//p' "$start_in_progress_path" | head -n 1
}

compose_unit_transition_active() {
	local state job
	job="$(systemctl --user show --property=Job --value "${podman_compose_service_name}.service" 2>/dev/null || true)"
	if [ -n "$job" ] && [ "$job" != "0" ]; then
		return 0
	fi
	state="$(systemctl --user show --property=ActiveState --value "${podman_compose_service_name}.service" 2>/dev/null || true)"
	case "$state" in
	activating | deactivating | reloading)
		return 0
		;;
	esac
	return 1
}

verify_transition_active() {
	verify_transition_message=""
	if start_in_progress_active; then
		verify_transition_message="podman compose start is still in progress for ${podman_compose_service_name}; not ready"
		return 0
	fi
	if compose_unit_transition_active; then
		verify_transition_message="podman compose unit is still transitioning for ${podman_compose_service_name}; not ready"
		return 0
	fi
	return 1
}

wait_for_verify_transition() {
	local now started_at
	started_at="$(now_epoch)"
	while verify_transition_active; do
		now="$(now_epoch)"
		if [ "$now" -ge "$((started_at + verify_transition_wait_seconds))" ]; then
			printf '%s\n' "$verify_transition_message" >&2
			return 1
		fi
		sleep 1
	done
}

start_in_progress_active() {
	local pid
	if [ -f "$start_in_progress_path" ]; then
		pid="$(start_in_progress_pid || true)"
		case "$pid" in
		"" | *[!0-9]*)
			printf '%s\n' "podman compose start marker has invalid pid for ${podman_compose_service_name}; clearing stale marker" >&2
			clear_start_in_progress
			return 1
			;;
		esac
		if kill -0 "$pid" 2>/dev/null; then
			return 0
		fi
		printf '%s\n' "podman compose start marker pid ${pid} is gone for ${podman_compose_service_name}; clearing stale marker" >&2
		clear_start_in_progress
		return 1
	fi
	return 1
}

start_in_progress_marker_active() {
	local marker pid
	marker="$1"
	[ -f "$marker" ] || return 1
	pid="$(sed -n 's/^pid=//p' "$marker" 2>/dev/null | head -n 1)"
	case "$pid" in
	"" | *[!0-9]*) return 1 ;;
	esac
	kill -0 "$pid" 2>/dev/null
}

any_compose_start_in_progress_active() {
	local marker
	if start_in_progress_active; then
		return 0
	fi
	for marker in "$working_dir"/../*/.podman-compose/start-in-progress; do
		[ -f "$marker" ] || continue
		[ "$marker" != "$start_in_progress_path" ] || continue
		if start_in_progress_marker_active "$marker"; then
			return 0
		fi
	done
	return 1
}

mark_stop_in_progress() {
	install -d -m 0750 "$generated_dir"
	{
		printf 'pid=%s\n' "$$"
		printf 'startedAt=%s\n' "$(now_epoch)"
	} >"${stop_in_progress_path}.tmp"
	mv -f "${stop_in_progress_path}.tmp" "$stop_in_progress_path"
}

clear_stop_in_progress() {
	rm -f -- "$stop_in_progress_path" "${stop_in_progress_path}.tmp"
}

post_stop_should_cleanup_failed_start() {
	[ -f "$start_in_progress_path" ] || return 1
	case "${SERVICE_RESULT-}" in
	"" | success)
		return 1
		;;
	*)
		return 0
		;;
	esac
}

compose_start_plan() {
	local force_recreate=0 mode=normal
	if compose_running_container_pids_missing; then
		force_recreate=1
	fi
	if compose_project_has_failed_containers; then
		force_recreate=1
	fi
	if [ "$force_recreate" -eq 1 ] || should_force_recreate; then
		force_recreate=1
		mode=force
	fi
	printf '%s\t%s\n' "$mode" "$force_recreate"
}

validate_compose_provider_inventory() {
	local state_json missing_services
	if ! state_json="$(compose_state_json)"; then
		printf '%s\n' "cannot query provider-created project inventory for ${podman_compose_service_name}" >&2
		return 1
	fi
	missing_services="$(
		printf '%s' "$state_json" |
			jq -r --argjson expected "$(expected_compose_services_json)" '
				def compose_service:
					.Labels["io.podman.compose.service"]
					// .Labels["com.docker.compose.service"]
					// empty;
				($expected - ([.[] | compose_service] | unique))[]?
			'
	)"
	if [ -n "$missing_services" ]; then
		printf '%s\n' "Compose provider did not create every expected service for ${podman_compose_service_name}:" >&2
		printf '%s\n' "$missing_services" >&2
		return 1
	fi
}

compose_start_transaction() {
	local requested_mode mode force_recreate status=0
	requested_mode="${1:-auto}"
	begin_rootless_mutation "compose start transaction" || return "$?"
	if ! backend_transition_admit; then
		rollback_rootless_mutation_clean
		return 1
	fi
	rm -f -- "$compose_dns_correction_marker_path"
	run_bootstrap_phase || status="$?"
	if [ "$status" -eq 0 ]; then
		case "$requested_mode" in
		auto)
			IFS=$'\t' read -r mode force_recreate < <(compose_start_plan)
			;;
		normal | force)
			mode="$requested_mode"
			force_recreate=0
			[ "$mode" = force ] && force_recreate=1
			;;
		*)
			printf '%s\n' "unsupported podman compose start mode: $requested_mode" >&2
			status=1
			;;
		esac
	fi
	if [ "$status" -eq 0 ]; then
		compose_up_once_mutating "$mode" || status="$?"
	fi
	if [ "$status" -eq 0 ]; then
		validate_compose_provider_inventory || status="$?"
	fi
	if [ "$status" -eq 0 ]; then
		compose_start_force_recreate="$force_recreate"
		commit_rootless_mutation
		return 0
	fi
	rollback_failed_compose_start "$status"
	return "$status"
}

# Compatibility entrypoint for sourced callers. It is deliberately a single
# provider attempt and never owns readiness or repair.
compose_up_checked() {
	case "$1" in
	force) compose_up_force_recreate ;;
	normal) compose_up ;;
	*)
		printf '%s\n' "unsupported podman compose start mode: $1" >&2
		return 1
		;;
	esac
}

compose_down_volumes() {
	local status=0
	compose_command_supervised "down --volumes" "$(compose_stop_timeout_seconds)" podman compose "${podman_compose_base_args[@]}" "${compose_args[@]}" "${compose_file_args[@]}" down --volumes || status="$?"
	return "$status"
}

compose_stop() {
	local status=0
	compose_command_supervised stop "$(compose_stop_timeout_seconds)" podman compose "${podman_compose_base_args[@]}" "${compose_args[@]}" "${compose_file_args[@]}" stop || status="$?"
	return "$status"
}

compose_pull() {
	local output_file line image status=0 fatal_seen=0

	if [ "${#pull_compose_file_args[@]}" -eq 0 ]; then
		return 0
	fi
	if [ "${#declared_images[@]}" -eq 0 ]; then
		return 0
	fi
	if [ "${#local_image_refs[@]}" -gt 0 ]; then
		for image in "${declared_images[@]}"; do
			(
				close_lifecycle_fds_for_child
				podman_no_notify pull "$image"
			)
		done
		return 0
	fi

	output_file="$(mktemp "${generated_dir}/pull-output.XXXXXX")"
	set +e
	(
		close_lifecycle_fds_for_child
		cd "$working_dir"
		podman_no_notify compose "${podman_compose_base_args[@]}" "${compose_args[@]}" "${pull_compose_file_args[@]}" pull 2>&1
	) | tee "$output_file"
	status="${PIPESTATUS[0]}"
	set -e

	while IFS= read -r line; do
		if compose_pull_fatal_line "$line"; then
			fatal_seen=1
			break
		fi
	done <"$output_file"
	rm -f "$output_file"

	if [ "$fatal_seen" -eq 1 ]; then
		printf '%s\n' "podman compose pull emitted fatal output for ${podman_compose_service_name}; treating pull as failed" >&2
		return 1
	fi
	return "$status"
}

compose_pull_with_retry() {
	local attempts delay_seconds attempt=1

	attempts="$(positive_integer_or_default "$image_pull_retry_attempts" 10)"
	delay_seconds="$(nonnegative_integer_or_default "$image_pull_retry_delay_seconds" 1)"
	while :; do
		if compose_pull; then
			return 0
		fi
		if [ "$attempt" -ge "$attempts" ]; then
			printf '%s\n' "podman compose pull failed for ${podman_compose_service_name} after ${attempts} attempt(s)" >&2
			return 1
		fi

		attempt=$((attempt + 1))
		printf '%s\n' "podman compose pull failed for ${podman_compose_service_name}; retrying attempt ${attempt}/${attempts} in ${delay_seconds}s" >&2
		sleep "$delay_seconds"
	done
}

compose_logs() {
	(
		close_lifecycle_fds_for_child
		cd "$working_dir"
		podman_no_notify compose "${podman_compose_base_args[@]}" "${compose_args[@]}" "${compose_file_args[@]}" logs "$@"
	)
}

rootless_mutation_marker_file() {
	if [ -n "$rootless_mutation_marker_path" ]; then
		printf '%s\n' "$rootless_mutation_marker_path"
		return 0
	fi
	[ -n "$runtime_dir" ] || return 1
	[ -n "$podman_compose_service_name" ] || return 1
	printf '%s\n' "$runtime_dir/podman-compose/rootless-mutations/${podman_compose_service_name}"
}

process_start_ticks() {
	local pid stat_line stat_after_comm
	local -a stat_fields
	pid="$1"
	[ -r "/proc/$pid/stat" ] || return 1
	IFS= read -r stat_line <"/proc/$pid/stat" || return 1
	stat_after_comm="${stat_line##*) }"
	read -r -a stat_fields <<<"$stat_after_comm"
	[ "${#stat_fields[@]}" -ge 20 ] || return 1
	printf '%s\n' "${stat_fields[19]}"
}

mark_rootless_mutation_in_progress() {
	local reason marker marker_dir tmp boot_id pid_start_ticks
	reason="${1:-rootless podman mutation}"
	marker="$(rootless_mutation_marker_file)" || return 0
	marker_dir="${marker%/*}"
	tmp="${marker}.tmp.$$"
	boot_id="$(runtime_preflight_boot_id)" || return 1
	pid_start_ticks="$(process_start_ticks "$$")" || return 1
	install -d -m 0700 "$marker_dir"
	{
		printf 'pid=%s\n' "$$"
		printf 'pidStartTicks=%s\n' "$pid_start_ticks"
		printf 'bootId=%s\n' "$boot_id"
		printf 'service=%s\n' "$podman_compose_service_name"
		printf 'reason=%s\n' "$reason"
		printf 'startedAt=%s\n' "$(now_epoch)"
	} >"$tmp"
	mv -f "$tmp" "$marker"
}

clear_rootless_mutation_in_progress() {
	local marker pid
	marker="$(rootless_mutation_marker_file)" || return 0
	[ -f "$marker" ] || return 0
	pid="$(sed -n 's/^pid=//p' "$marker" 2>/dev/null | head -n 1)"
	if [ -z "$pid" ] || [ "$pid" = "$$" ]; then
		rm -f -- "$marker" "${marker}.tmp.$$"
	fi
}

rootless_mutation_preflight_current() {
	local policy
	policy="${1:-current}"
	case "$policy" in
	current | drain | prepare) ;;
	*)
		printf 'unsupported rootless mutation preflight policy: %s\n' "$policy" >&2
		return 1
		;;
	esac
	if [ "$rootless_runtime_preflight_suppressed" -eq 1 ] ||
		[ -z "$runtime_preflight_metadata" ]; then
		return 0
	fi
	load_runtime_preflight_metadata
	# Pre-activation image preparation may share the rootless image store lock,
	# but it must never reconcile or recreate live projects. A generation-stamp
	# mismatch alone is safe for an image pull. Durable dirty state is not: defer
	# that pull to the activation graph, whose preflight unit owns repair.
	if [ "$policy" = prepare ]; then
		if [ -f "$runtime_preflight_required_path" ] ||
			[ -f "$rootless_runtime_dirty_path" ] ||
			stale_rootless_mutation_markers_present; then
			printf '%s\n' \
				"rootless Podman runtime needs activation preflight for ${podman_compose_service_name}; deferring image preparation" >&2
			return 75
		fi
		return 0
	fi
	if ! runtime_preflight_needs_reconcile; then
		return 0
	fi
	if [ "$policy" = drain ] &&
		[ ! -f "$runtime_preflight_required_path" ] &&
		[ ! -f "$rootless_runtime_dirty_path" ] &&
		! stale_rootless_mutation_markers_present; then
		printf '%s\n' "allowing clean rootless drain across preflight generation change for ${podman_compose_service_name}"
		return 0
	fi
	printf '%s\n' \
		"rootless Podman runtime is not preflight-clean for ${podman_compose_service_name}; refusing inline repair" \
		"run the generated per-user runtime preflight before retrying this mutation" >&2
	return 1
}

begin_rootless_mutation() {
	local reason preflight_policy preflight_rc=0
	reason="${1:-rootless podman mutation}"
	preflight_policy="${2:-current}"
	if [ "$podman_rootless_lifecycle_lock_depth" -gt 0 ]; then
		podman_rootless_lifecycle_lock_depth="$((podman_rootless_lifecycle_lock_depth + 1))"
		return 0
	fi
	install -d -m 0700 "$runtime_dir/podman-compose"
	# Historical filename kept so host health tooling and older deployments
	# observe the same per-user rootless mutation transaction.
	exec 6>"$runtime_dir/podman-compose/rootless-lifecycle-v1.lock"
	flock -x 6
	podman_rootless_lifecycle_lock_depth=1
	rootless_mutation_preflight_current "$preflight_policy" || preflight_rc="$?"
	if [ "$preflight_rc" -ne 0 ]; then
		podman_rootless_lifecycle_lock_depth=0
		flock -u 6
		exec 6>&-
		return "$preflight_rc"
	fi
	mark_rootless_mutation_in_progress "$reason"
}

begin_rootless_mutation_timeout() {
	local timeout_seconds reason preflight_policy preflight_rc=0
	timeout_seconds="$1"
	reason="${2:-rootless podman mutation}"
	preflight_policy="${3:-current}"
	if [ "$podman_rootless_lifecycle_lock_depth" -gt 0 ]; then
		podman_rootless_lifecycle_lock_depth="$((podman_rootless_lifecycle_lock_depth + 1))"
		return 0
	fi
	install -d -m 0700 "$runtime_dir/podman-compose"
	exec 6>"$runtime_dir/podman-compose/rootless-lifecycle-v1.lock"
	if ! flock_timeout 6 "$timeout_seconds"; then
		exec 6>&-
		return 1
	fi
	podman_rootless_lifecycle_lock_depth=1
	rootless_mutation_preflight_current "$preflight_policy" || preflight_rc="$?"
	if [ "$preflight_rc" -ne 0 ]; then
		podman_rootless_lifecycle_lock_depth=0
		flock -u 6
		exec 6>&-
		return "$preflight_rc"
	fi
	mark_rootless_mutation_in_progress "$reason"
}

begin_image_pull_mutation() {
	local reason mutation_rc=0
	reason="$1"
	if [ "$image_pull_preflight_policy" = prepare ]; then
		if ! lock_lifecycle_exclusive_timeout "$prepare_lock_timeout_seconds"; then
			printf '%s\n' "image preparation deferred while lifecycle is busy for ${podman_compose_service_name}" >&2
			return 75
		fi
		begin_rootless_mutation_timeout \
			"$prepare_lock_timeout_seconds" "$reason" prepare || mutation_rc="$?"
		if [ "$mutation_rc" -ne 0 ]; then
			unlock_lifecycle_exclusive
			printf '%s\n' "image preparation deferred while rootless Podman is busy for ${podman_compose_service_name}" >&2
			return 75
		fi
		return 0
	fi

	lock_lifecycle_exclusive
	begin_rootless_mutation "$reason" "$image_pull_preflight_policy" || mutation_rc="$?"
	if [ "$mutation_rc" -ne 0 ]; then
		unlock_lifecycle_exclusive
		return "$mutation_rc"
	fi
}

release_rootless_mutation_lock() {
	flock -u 6
	exec 6>&-
}

commit_rootless_mutation() {
	if [ "$podman_rootless_lifecycle_lock_depth" -le 0 ]; then
		return 0
	fi
	podman_rootless_lifecycle_lock_depth="$((podman_rootless_lifecycle_lock_depth - 1))"
	if [ "$podman_rootless_lifecycle_lock_depth" -gt 0 ]; then
		return 0
	fi
	clear_rootless_mutation_in_progress
	release_rootless_mutation_lock
}

rollback_rootless_mutation_clean() {
	commit_rootless_mutation
}

leave_rootless_runtime_dirty() {
	local reason tmp marker
	reason="${1:-rootless mutation outcome could not be proven clean}"
	[ "$podman_rootless_lifecycle_lock_depth" -gt 0 ] || return 0
	install -d -m 0700 "$runtime_dir/podman-compose"
	tmp="${rootless_runtime_dirty_path}.tmp.$$"
	marker="$(rootless_mutation_marker_file 2>/dev/null || true)"
	{
		printf 'service=%s\n' "$podman_compose_service_name"
		printf 'reason=%s\n' "$reason"
		printf 'marker=%s\n' "$marker"
		printf 'recordedAt=%s\n' "$(now_epoch)"
	} >"$tmp"
	mv -f "$tmp" "$rootless_runtime_dirty_path"
	: >"$runtime_preflight_required_path"
	podman_rootless_lifecycle_lock_depth=0
	release_rootless_mutation_lock
}

# Compatibility names for out-of-tree helper consumers. New code uses the
# explicit transaction outcome names above.
podman_rootless_lifecycle_lock() {
	begin_rootless_mutation "$@"
}

podman_rootless_lifecycle_lock_timeout() {
	begin_rootless_mutation_timeout "$@"
}

podman_rootless_lifecycle_unlock() {
	commit_rootless_mutation
}

podman_rootless_observation_lock() {
	if [ "$podman_rootless_observation_lock_depth" -gt 0 ]; then
		podman_rootless_observation_lock_depth="$((podman_rootless_observation_lock_depth + 1))"
		return 0
	fi
	install -d -m 0700 "$runtime_dir/podman-compose"
	exec 7>"$runtime_dir/podman-compose/rootless-lifecycle-v1.lock"
	flock -s 7
	podman_rootless_observation_lock_depth=1
}

podman_rootless_observation_unlock() {
	if [ "$podman_rootless_observation_lock_depth" -le 0 ]; then
		return 0
	fi
	podman_rootless_observation_lock_depth="$((podman_rootless_observation_lock_depth - 1))"
	if [ "$podman_rootless_observation_lock_depth" -gt 0 ]; then
		return 0
	fi
	flock -u 7
	exec 7>&-
}

prune_stale_aardvark_dns_configs_mutating() {
	local aardvark_dir running_ids network_list network_json config_file config_name configured_gateway network_gateway
	local attached_ids line container_id has_running_attached_entry network_name
	local -a network_names=()

	aardvark_dns_configs_pruned=0
	[ -n "$runtime_dir" ] || return 0
	aardvark_dir="$runtime_dir/containers/networks/aardvark-dns"
	[ -d "$aardvark_dir" ] || return 0
	if ! running_ids="$(podman_no_notify ps -q --no-trunc 2>/dev/null)"; then
		printf '%s\n' "cannot query running containers while reconciling podman aardvark DNS for ${podman_compose_service_name}" >&2
		return 1
	fi
	if ! network_list="$(podman_no_notify network ls --format '{{.Name}}' 2>/dev/null)"; then
		printf '%s\n' "cannot query podman networks while reconciling aardvark DNS for ${podman_compose_service_name}" >&2
		return 1
	fi
	while IFS= read -r network_name; do
		[ -n "$network_name" ] || continue
		network_names+=("$network_name")
	done <<<"$network_list"
	if [ "${#network_names[@]}" -gt 0 ]; then
		if ! network_json="$(podman_no_notify network inspect "${network_names[@]}" 2>/dev/null)"; then
			printf '%s\n' "cannot inspect podman networks while reconciling aardvark DNS for ${podman_compose_service_name}" >&2
			return 1
		fi
	else
		network_json='[]'
	fi

	for config_file in "$aardvark_dir"/*; do
		[ -f "$config_file" ] || continue
		config_name="${config_file##*/}"
		[ "$config_name" = "aardvark.pid" ] && continue
		configured_gateway="$(sed -n '/[^[:space:]]/ { s/[[:space:]].*$//; p; q; }' "$config_file")"
		network_gateway="$(
			jq -r --arg name "$config_name" '
				first(
					.[]
					| select((.name // .Name // "") == $name)
					| (.subnets[0].gateway // .Subnets[0].Gateway // "")
				) // empty
			' <<<"$network_json"
		)"
		if [ -z "$network_gateway" ]; then
			printf '%s\n' "removing stale podman aardvark DNS config with no matching network for ${podman_compose_service_name}: ${config_file}"
			rm -f -- "$config_file"
			aardvark_dns_configs_pruned=1
			continue
		fi
		if [ -n "$configured_gateway" ] && [ "$configured_gateway" != "$network_gateway" ]; then
			printf '%s\n' "removing stale podman aardvark DNS config with gateway ${configured_gateway}; network ${config_name} uses ${network_gateway}: ${config_file}"
			rm -f -- "$config_file"
			aardvark_dns_configs_pruned=1
			continue
		fi
		attached_ids="$(
			jq -r --arg name "$config_name" '
				(
					first(
					.[]
					| select((.name // .Name // "") == $name)
					) // {}
				)
				| ((.containers // .Containers // {}) | keys[]?)
			' <<<"$network_json"
		)"
		has_running_attached_entry=0
		while IFS= read -r line; do
			container_id="${line%%[[:space:]]*}"
			[ -n "$container_id" ] || continue
			case "$container_id" in *.*.*.*) continue ;; esac
			if grep -Fxq "$container_id" <<<"$running_ids" 2>/dev/null &&
				grep -Fxq "$container_id" <<<"$attached_ids" 2>/dev/null; then
				has_running_attached_entry=1
				break
			fi
		done <"$config_file"
		if [ "$has_running_attached_entry" -eq 0 ]; then
			printf '%s\n' "removing stale podman aardvark DNS config with no running containers attached to ${config_name} for ${podman_compose_service_name}: ${config_file}"
			rm -f -- "$config_file"
			aardvark_dns_configs_pruned=1
		fi
	done
}

reload_compose_project_networks_mutating() {
	local container container_ids
	local -a containers=()

	if ! container_ids="$(running_compose_project_container_ids)"; then
		printf '%s\n' "cannot query running project containers while reloading networks for ${podman_compose_service_name}" >&2
		return 1
	fi
	while IFS= read -r container; do
		[ -n "$container" ] || continue
		containers+=("$container")
	done <<<"$container_ids"
	if [ "${#containers[@]}" -eq 0 ]; then
		printf '%s\n' "cannot reload project networks for ${podman_compose_service_name}: no running project containers found" >&2
		return 1
	fi

	printf '%s\n' "reloading Podman networks for ${podman_compose_service_name} after direct peer-service DNS failure"
	podman_no_notify network reload "${containers[@]}"
}

running_compose_project_container_ids() {
	(
		close_lifecycle_fds_for_child
		cd /
		podman_no_notify_timeout "$compose_monitor_timeout_seconds" ps \
			--filter "label=com.docker.compose.project.working_dir=$working_dir" \
			--format '{{.ID}}'
	)
}

runtime_preflight_boot_id() {
	if [ -n "${NIX_PODMAN_COMPOSE_BOOT_ID-}" ]; then
		printf '%s\n' "$NIX_PODMAN_COMPOSE_BOOT_ID"
		return 0
	fi
	cat /proc/sys/kernel/random/boot_id
}

runtime_preflight_stamp_current() {
	local boot_id stamped_boot_id stamped_token

	[ -f "$runtime_preflight_stamp_path" ] || return 1
	boot_id="$(runtime_preflight_boot_id)" || return 1
	stamped_boot_id="$(sed -n 's/^bootId=//p' "$runtime_preflight_stamp_path" | head -n 1)"
	stamped_token="$(sed -n 's/^token=//p' "$runtime_preflight_stamp_path" | head -n 1)"
	[ "$stamped_boot_id" = "$boot_id" ] && [ "$stamped_token" = "$runtime_preflight_token" ]
}

rootless_mutation_marker_is_stale() {
	local marker pid marker_boot_id marker_pid_start_ticks boot_id pid_start_ticks
	marker="$1"
	[ -f "$marker" ] || return 1
	pid="$(sed -n 's/^pid=//p' "$marker" 2>/dev/null | head -n 1)"
	case "$pid" in
	"" | *[!0-9]*) return 0 ;;
	esac
	marker_boot_id="$(sed -n 's/^bootId=//p' "$marker" 2>/dev/null | head -n 1)"
	marker_pid_start_ticks="$(sed -n 's/^pidStartTicks=//p' "$marker" 2>/dev/null | head -n 1)"
	[ -n "$marker_boot_id" ] || return 0
	[ -n "$marker_pid_start_ticks" ] || return 0
	boot_id="$(runtime_preflight_boot_id)" || return 0
	[ "$marker_boot_id" = "$boot_id" ] || return 0
	pid_start_ticks="$(process_start_ticks "$pid")" || return 0
	[ "$marker_pid_start_ticks" != "$pid_start_ticks" ]
}

stale_rootless_mutation_markers_present() {
	local marker marker_dir
	marker_dir="$runtime_dir/podman-compose/rootless-mutations"
	[ -d "$marker_dir" ] || return 1
	for marker in "$marker_dir"/*; do
		[ -f "$marker" ] || continue
		rootless_mutation_marker_is_stale "$marker" && return 0
	done
	return 1
}

clear_stale_rootless_mutation_markers() {
	local marker marker_dir
	marker_dir="$runtime_dir/podman-compose/rootless-mutations"
	[ -d "$marker_dir" ] || return 0
	for marker in "$marker_dir"/*; do
		[ -f "$marker" ] || continue
		if rootless_mutation_marker_is_stale "$marker"; then
			printf '%s\n' "clearing reconciled abandoned rootless podman mutation: ${marker##*/}"
			rm -f -- "$marker"
		fi
	done
}

runtime_preflight_needs_reconcile() {
	[ -f "$runtime_preflight_required_path" ] ||
		[ -f "$rootless_runtime_dirty_path" ] ||
		! runtime_preflight_stamp_current ||
		stale_rootless_mutation_markers_present
}

load_runtime_preflight_service_entry() {
	local metadata_file
	metadata_file="$1"
	podman_compose_metadata="$metadata_file"

	podman_compose_service_name="$(jq -r '.serviceName' "$metadata_file")"
	backend="$(jq -r '.backend // "compose"' "$metadata_file")"
	working_dir="$(jq -r '.workingDir' "$metadata_file")"
	adoption_stamp="$(jq -r '.adoptionStamp // ""' "$metadata_file")"
	long_running="$(jq -r 'if has("longRunning") then .longRunning else true end' "$metadata_file")"
	generated_dir="$working_dir/.podman-compose"
	state_path="$generated_dir/state.json"
	start_in_progress_path="$generated_dir/start-in-progress"
	expected_compose_services=()
	while IFS= read -r compose_service; do
		[ -n "$compose_service" ] || continue
		expected_compose_services+=("$compose_service")
	done < <(jq -r '.expectedComposeServices[]?' "$metadata_file")
	if [ "$backend" = quadlet ]; then
		quadlet_load_backend_metadata
	fi
}

runtime_preflight_project_recreate_status() {
	local container container_ids state_json failing_states recreate=1

	if [ "$backend" = quadlet ]; then
		quadlet_runtime_preflight_recreate_status
		return
	fi

	if ! container_ids="$(compose_project_container_ids)"; then
		printf '%s\n' "cannot query podman containers during runtime preflight for ${podman_compose_service_name}" >&2
		return 2
	fi
	while IFS= read -r container; do
		[ -n "$container" ] || continue
		if running_container_pid_missing "$container"; then
			recreate=0
		fi
	done <<<"$container_ids"

	if ! state_json="$(compose_state_json)"; then
		printf '%s\n' "cannot query podman project state during runtime preflight for ${podman_compose_service_name}" >&2
		return 2
	fi
	if [ "$long_running" = "true" ]; then
		failing_states="$(printf '%s' "$state_json" | failing_states_report)"
		if [ -n "$failing_states" ]; then
			printf '%s\n' "podman compose project has non-running containers during runtime preflight for ${podman_compose_service_name}" >&2
			printf '%s\n' "$failing_states" >&2
			recreate=0
		fi
	fi
	return "$recreate"
}

runtime_preflight_project_cleanup_complete() {
	local container_ids normal_names storage_names container

	if [ "$backend" = quadlet ]; then
		quadlet_cleanup_postcondition
		return
	fi

	if ! container_ids="$(compose_project_container_ids)"; then
		printf '%s\n' "cannot verify podman project container cleanup during runtime preflight for ${podman_compose_service_name}" >&2
		return 1
	fi
	if [ -n "$container_ids" ]; then
		printf '%s\n' "podman project containers remain after runtime preflight cleanup for ${podman_compose_service_name}:" >&2
		printf '%s\n' "$container_ids" >&2
		return 1
	fi
	if ! normal_names="$(podman_no_notify container list --all --format '{{.Names}}')"; then
		printf '%s\n' "cannot verify podman container-name cleanup during runtime preflight for ${podman_compose_service_name}" >&2
		return 1
	fi
	if ! storage_names="$(podman_no_notify container list --all --storage --format '{{.Names}}')"; then
		printf '%s\n' "cannot verify podman storage cleanup during runtime preflight for ${podman_compose_service_name}" >&2
		return 1
	fi

	while IFS= read -r container; do
		[ -n "$container" ] || continue
		if grep -Fxq "$container" <<<"$normal_names" ||
			grep -Fxq "$container" <<<"$storage_names"; then
			printf '%s\n' "podman container remains after runtime preflight cleanup for ${podman_compose_service_name}: ${container}" >&2
			return 1
		fi
	done < <(compose_project_container_names)
	return 0
}

runtime_preflight_reconcile_projects() {
	local encoded entry metadata_file transition_status project_status cleanup_status failed=0

	runtime_preflight_repaired=0
	while IFS= read -r encoded; do
		[ -n "$encoded" ] || continue
		entry="$(printf '%s' "$encoded" | base64 -d)"
		metadata_file="$(jq -r '.metadataFile' <<<"$entry")"
		load_runtime_preflight_service_entry "$metadata_file"
		transition_status=0
		backend_transition_admit || transition_status="$?"
		case "$transition_status" in
		0) ;;
		1)
			printf 'podman runtime preflight is deferring service-local backend transition for %s\n' \
				"$podman_compose_service_name" >&2
			continue
			;;
		*)
			failed=1
			continue
			;;
		esac
		project_status=0
		runtime_preflight_project_recreate_status || project_status="$?"
		case "$project_status" in
		0)
			printf '%s\n' "podman runtime preflight is recreating inconsistent project ${podman_compose_service_name}"
			cleanup_status=0
			if [ "$backend" = quadlet ]; then
				quadlet_runtime_preflight_cleanup || cleanup_status="$?"
			else
				remove_compose_project_containers || cleanup_status="$?"
			fi
			if runtime_preflight_project_cleanup_complete; then
				if [ "$cleanup_status" -ne 0 ]; then
					printf '%s\n' "podman runtime preflight cleanup reported transient errors but reached a clean project state for ${podman_compose_service_name}"
				fi
				runtime_preflight_repaired=1
			else
				failed=1
			fi
			;;
		1) ;;
		*) failed=1 ;;
		esac
	done < <(jq -r '.services[] | @base64' "$runtime_preflight_metadata")
	return "$failed"
}

runtime_preflight_reconcile_locked() {
	local caller_service_name caller_marker_path

	caller_service_name="$podman_compose_service_name"
	caller_marker_path="$rootless_mutation_marker_path"
	: >"$runtime_preflight_required_path"
	runtime_preflight_had_stale_marker=0
	if stale_rootless_mutation_markers_present; then
		runtime_preflight_had_stale_marker=1
	fi
	if ! runtime_preflight_reconcile_projects; then
		podman_compose_service_name="$caller_service_name"
		rootless_mutation_marker_path="$caller_marker_path"
		return 1
	fi

	podman_compose_service_name="$caller_service_name"
	rootless_mutation_marker_path="$caller_marker_path"
	if ! prune_stale_aardvark_dns_configs_mutating; then
		return 1
	fi
	record_runtime_preflight_stamp
	clear_stale_rootless_mutation_markers
	rm -f -- "$runtime_preflight_required_path" "$rootless_runtime_dirty_path"
}

record_runtime_preflight_stamp() {
	local boot_id tmp
	boot_id="$(runtime_preflight_boot_id)"
	tmp="${runtime_preflight_stamp_path}.tmp.$$"
	{
		printf 'bootId=%s\n' "$boot_id"
		printf 'token=%s\n' "$runtime_preflight_token"
		printf 'completedAt=%s\n' "$(now_epoch)"
	} >"$tmp"
	mv -f "$tmp" "$runtime_preflight_stamp_path"
}

cmd_runtime_preflight() {
	load_runtime_preflight_metadata
	install -d -m 0700 "$runtime_dir/podman-compose/rootless-mutations"
	if ! runtime_preflight_needs_reconcile; then
		return 0
	fi

	rootless_runtime_preflight_suppressed=1
	begin_rootless_mutation "rootless runtime preflight"
	rootless_runtime_preflight_suppressed=0
	if ! runtime_preflight_needs_reconcile; then
		commit_rootless_mutation
		return 0
	fi
	if ! runtime_preflight_reconcile_locked; then
		leave_rootless_runtime_dirty "per-user runtime preflight could not prove a clean runtime"
		return 1
	fi
	commit_rootless_mutation
}

compose_dns_dependency_pairs() {
	awk '
		$0 == "services:" {
			in_services = 1
			next
		}
		in_services && /^[^[:space:]]/ { exit }
		in_services && /^  [^[:space:]].*:$/ {
			service = $0
			sub(/^  /, "", service)
			sub(/:$/, "", service)
			in_dependencies = 0
			next
		}
		service != "" && /^    depends_on:$/ {
			in_dependencies = 1
			next
		}
		in_dependencies && /^      [^[:space:]].*:$/ {
			dependency = $0
			sub(/^      /, "", dependency)
			sub(/:$/, "", dependency)
			print service "\t" dependency
			next
		}
		in_dependencies && /^    [^[:space:]]/ { in_dependencies = 0 }
	'
}

load_compose_dns_dependencies() {
	local normalized_config dependency_pairs

	[ "$compose_dns_dependencies_loaded" -eq 0 ] || return 0
	compose_dns_dependencies_loaded=1
	compose_dns_dependencies_json='[]'
	[ "$long_running" = "true" ] || return 0

	if ! normalized_config="$(
		close_lifecycle_fds_for_child
		cd "$working_dir"
		podman_no_notify compose \
			"${podman_compose_base_args[@]}" \
			"${compose_args[@]}" \
			"${compose_file_args[@]}" \
			config 2>/dev/null
	)"; then
		printf '%s\n' \
			"podman compose DNS probe skipped for ${podman_compose_service_name}:" \
			"cannot read normalized dependency config" >&2
		return 0
	fi
	dependency_pairs="$(printf '%s\n' "$normalized_config" | compose_dns_dependency_pairs)"
	[ -n "$dependency_pairs" ] || return 0
	compose_dns_dependencies_json="$(
		printf '%s\n' "$dependency_pairs" |
			jq -R 'split("\t") | select(length == 2) | {service: .[0], dependency: .[1]}' |
			jq -s -c .
	)"
}

compose_dns_probe_targets() {

	[ "$long_running" = "true" ] || return 1
	[ "$compose_dns_dependencies_json" != '[]' ] || return 0

	close_lifecycle_fds_for_child
	cd /
	podman_no_notify ps \
		--filter "label=com.docker.compose.project.working_dir=$working_dir" \
		--format json |
		jq -r --argjson dependencies "$compose_dns_dependencies_json" '
			. as $containers
			| .[]
			| select((.State // "") == "running")
			| (.ID // .Id // "") as $container_id
			| (.Labels["io.podman.compose.service"] // .Labels["com.docker.compose.service"] // "") as $service
			| $dependencies[]
			| select(.service == $service and .dependency != $service)
			| .dependency as $dependency
			| first(
				$containers[]
				| select((.State // "") == "running")
				| select((.Labels["io.podman.compose.service"] // .Labels["com.docker.compose.service"] // "") == $dependency)
				| (.ID // .Id // "")
			) as $dependency_container_id
			| [$container_id, $dependency_container_id, $service, $dependency]
			| select(all(.[]; . != ""))
			| @tsv
		'
}

compose_dns_network_checks() {
	local container_id="$1" dependency_container_id="$2" inspect_json network_names network_json
	local -a networks=()
	if ! inspect_json="$(podman_no_notify inspect "$container_id" "$dependency_container_id")"; then
		return 1
	fi
	if ! network_names="$(
		printf '%s' "$inspect_json" |
			jq -r --arg caller "$container_id" --arg dependency "$dependency_container_id" '
				def id: (.Id // .ID // "");
				([.[] | select(id == $caller) | (.NetworkSettings.Networks // {}) | keys[]] // []) as $caller_networks
				| ([.[] | select(id == $dependency) | (.NetworkSettings.Networks // {}) | keys[]] // []) as $dependency_networks
				| ($caller_networks - ($caller_networks - $dependency_networks))[]?
			'
	)"; then
		return 1
	fi
	[ -n "$network_names" ] || return 0
	mapfile -t networks <<<"$network_names"
	if ! network_json="$(podman_no_notify network inspect "${networks[@]}")"; then
		return 1
	fi
	jq -r \
		--arg caller "$container_id" \
		--arg dependency "$dependency_container_id" \
		--argjson containers "$inspect_json" '
			def id: (.Id // .ID // "");
			def network_name: (.name // .Name // "");
			def dns_enabled: (.dns_enabled // .DNSEnabled // false);
			def gateways: [(.subnets // .Subnets // [])[]? | (.gateway // .Gateway // empty)];
			def attachment($container; $network):
				$containers[]
				| select(id == $container)
				| .NetworkSettings.Networks[$network];
			.[]
			| network_name as $network
			| select($network != "" and dns_enabled)
			| gateways[] as $gateway
			| [
				$containers[]
				| select(id == $caller)
				| (.State.Pid // .State.PID // 0)
			][0] as $pid
			| [
				attachment($dependency; $network)
				| (.IPAddress // empty),
				  (.GlobalIPv6Address // empty),
				  (.IP6Address // empty)
				| select(. != "")
			] as $expected
			| select($pid > 0 and $gateway != "" and ($expected | length) > 0)
			| {network: $network, pid: $pid, gateway: $gateway, expected: $expected}
			| @base64
		' <<<"$network_json"
}

compose_dns_query() {
	local pid="$1" gateway="$2" dependency="$3" query_type="$4"
	local -a namespace_command=(nsenter -t "$pid" -n --)
	if [ "$(id -u)" -ne 0 ]; then
		namespace_command=(podman unshare "${namespace_command[@]}")
	fi
	close_lifecycle_fds_for_child
	cd /
	timeout 5 env -u NOTIFY_SOCKET -u WATCHDOG_PID -u WATCHDOG_USEC \
		"${namespace_command[@]}" \
		dig "@${gateway}" "$dependency" "$query_type" \
		+time=2 +tries=1 +noall +comments +answer
}

verify_compose_dns_network() {
	local encoded="$1" dependency="$2" check network pid gateway expected_json query_type output status dns_status answers
	check="$(printf '%s' "$encoded" | base64 -d)"
	network="$(jq -r '.network' <<<"$check")"
	pid="$(jq -r '.pid' <<<"$check")"
	gateway="$(jq -r '.gateway' <<<"$check")"
	expected_json="$(jq -c '.expected' <<<"$check")"
	for query_type in A AAAA; do
		output=""
		status=0
		output="$(compose_dns_query "$pid" "$gateway" "$dependency" "$query_type" 2>&1)" || status="$?"
		if [ "$status" -ne 0 ]; then
			printf 'DNS namespace query failed for network %s with status %s\n' "$network" "$status" >&2
			[ -n "$output" ] && printf '%s\n' "$output" >&2
			return "$compose_dns_indeterminate_exit_status"
		fi
		dns_status="$(sed -n 's/.*status: \([A-Z]*\).*/\1/p' <<<"$output" | head -n 1)"
		case "$dns_status" in
		NOERROR | NXDOMAIN) ;;
		*)
			printf 'DNS namespace query returned indeterminate status %s on network %s\n' "${dns_status:-unknown}" "$network" >&2
			return "$compose_dns_indeterminate_exit_status"
			;;
		esac
		answers="$(awk '$1 !~ /^;/ && NF > 0 { print $NF }' <<<"$output")"
		if jq -e --arg answers "$answers" 'any(.[]; . as $expected | ($answers | split("\n") | index($expected)) != null)' <<<"$expected_json" >/dev/null; then
			return 0
		fi
	done
	return 1
}

verify_compose_dns() {
	local targets container_id dependency_container_id compose_service dependency checks encoded status indeterminate=0 checked=0

	load_compose_dns_dependencies
	[ "$long_running" = "true" ] || return 0
	[ "$compose_dns_dependencies_json" != '[]' ] || return 0
	if ! targets="$(compose_dns_probe_targets)"; then
		printf '%s\n' \
			"podman compose DNS probe was indeterminate for ${podman_compose_service_name}:" \
			"could not query running dependency probe targets" >&2
		return "$compose_dns_indeterminate_exit_status"
	fi
	while IFS=$'\t' read -r container_id dependency_container_id compose_service dependency; do
		[ -n "$container_id" ] && [ -n "$dependency_container_id" ] && [ -n "$compose_service" ] && [ -n "$dependency" ] || continue
		if ! checks="$(compose_dns_network_checks "$container_id" "$dependency_container_id")"; then
			printf '%s\n' \
				"podman compose DNS probe was indeterminate for ${podman_compose_service_name}:" \
				"could not inspect shared networks for ${compose_service} and ${dependency}" >&2
			return "$compose_dns_indeterminate_exit_status"
		fi
		[ -n "$checks" ] || continue
		while IFS= read -r encoded; do
			[ -n "$encoded" ] || continue
			checked=1
			status=0
			verify_compose_dns_network "$encoded" "$dependency" || status="$?"
			case "$status" in
			0) ;;
			1)
				printf '%s\n' \
					"podman compose DNS probe failed for ${podman_compose_service_name}:" \
					"${compose_service} cannot resolve declared dependency ${dependency}" >&2
				return 1
				;;
			*) indeterminate=1 ;;
			esac
		done <<<"$checks"
	done <<<"$targets"
	if [ "$indeterminate" -eq 1 ]; then
		return "$compose_dns_indeterminate_exit_status"
	fi
	if [ "$checked" -eq 0 ]; then
		printf '%s\n' "podman compose DNS probe skipped for ${podman_compose_service_name}: no shared DNS-enabled network"
	fi
	return 0
}

verify_compose_dns_stable() {
	local status=0

	if [ "$podman_rootless_lifecycle_lock_depth" -gt 0 ]; then
		if verify_compose_dns; then
			return 0
		else
			status="$?"
		fi
		return "$status"
	fi

	podman_rootless_observation_lock
	if verify_compose_dns; then
		status=0
	else
		status="$?"
	fi
	podman_rootless_observation_unlock
	return "$status"
}

running_compose_services() {
	(
		close_lifecycle_fds_for_child
		cd /
		podman_no_notify ps \
			--filter "label=com.docker.compose.project.working_dir=$working_dir" \
			--format json |
			jq -r '.[] | (.Labels["io.podman.compose.service"] // .Labels["com.docker.compose.service"] // empty)' |
			sort -u
	)
}

verify_expected_compose_services() {
	local running_services="" missing_services="" compose_service=""

	[ "$long_running" = "true" ] || return 0
	[ "${#expected_compose_services[@]}" -gt 0 ] || return 0

	running_services="$(running_compose_services)"
	for compose_service in "${expected_compose_services[@]}"; do
		if ! grep -Fxq "$compose_service" <<<"$running_services"; then
			missing_services="${missing_services}${missing_services:+
}${compose_service}"
		fi
	done

	if [ -n "$missing_services" ]; then
		printf '%s\n' "podman compose is missing running containers for expected services:" >&2
		printf '%s\n' "$missing_services" >&2
		return 1
	fi
}

compose_reload_signal() {
	(
		close_lifecycle_fds_for_child
		cd "$working_dir"
		podman_no_notify compose "${podman_compose_base_args[@]}" "${compose_args[@]}" "${compose_file_args[@]}" kill --signal "$reload_signal" "${reload_services[@]}" 2>&1
	)
}

policy_allows_recreate() {
	case "$reconcile_policy" in
	auto | recreate)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

should_force_recreate() {
	local applied_recreate_tag applied_recreate_stamp applied_recreate_class_stamp
	migrate_legacy_runtime_state_if_needed
	migrate_runtime_state_version_if_needed
	if [ "$adopt_existing" = "true" ]; then
		return 0
	fi
	if ! policy_allows_recreate; then
		return 1
	fi
	if policy_transition_forces_recreate; then
		return 0
	fi
	if [ "$recreate_tag" != "0" ]; then
		applied_recreate_tag="$(last_applied_recreate_tag)"
		if [ "$recreate_tag" != "$applied_recreate_tag" ]; then
			return 0
		fi
	fi
	if [ "$reconcile_policy" != recreate ]; then
		applied_recreate_class_stamp="$(last_applied_recreate_class_stamp)"
		if [ -n "$recreate_class_stamp" ] && [ "$applied_recreate_class_stamp" = "$recreate_class_stamp" ]; then
			return 1
		fi
	fi
	if [ -n "$recreate_stamp" ]; then
		applied_recreate_stamp="$(last_applied_recreate_stamp)"
		[ "$recreate_stamp" != "$applied_recreate_stamp" ] && return 0
	fi
	return 1
}

runtime_state_matches() {
	jq -e \
		--argjson version "$runtime_state_version" \
		--arg kind "$runtime_state_kind" \
		--arg adoptionStamp "$adoption_stamp" \
		'(.version == $version) and (.kind == $kind) and (.adoptionStamp == $adoptionStamp)' \
		"$state_path" >/dev/null 2>&1
}

runtime_state_field() {
	local field default
	field="$1"
	default="$2"
	if [ -f "$state_path" ] && runtime_state_matches; then
		jq -r --arg field "$field" --arg default "$default" '.[$field] // $default' "$state_path" 2>/dev/null || printf '%s\n' "$default"
	else
		printf '%s\n' "$default"
	fi
}

existing_runtime_state_json() {
	if [ -f "$state_path" ] && runtime_state_matches; then
		jq -c '.' "$state_path" 2>/dev/null || printf '{}'
	else
		printf '{}'
	fi
}

current_backend_data_json() {
	jq -c '.backendData // {}' "$podman_compose_metadata" 2>/dev/null || printf '{}\n'
}

last_applied_backend() {
	runtime_state_field appliedBackend compose
}

last_applied_backend_data() {
	runtime_state_field appliedBackendData '{}'
}

backend_transition_compose_runtime_clean() {
	local container_ids
	if ! container_ids="$(compose_project_container_ids)"; then
		printf 'cannot inspect prior Compose runtime for backend transition of %s\n' \
			"$podman_compose_service_name" >&2
		return 2
	fi
	[ -z "$container_ids" ] || {
		printf 'prior Compose containers remain for backend transition of %s:\n%s\n' \
			"$podman_compose_service_name" "$container_ids" >&2
		return 1
	}
}

backend_transition_quadlet_unit_clean() {
	local active_state container_unit fragment_path load_state source_path source_path_actual state prior_data
	prior_data="$1"
	container_unit="$(jq -r '.quadlet.containerUnit // empty' <<<"$prior_data")"
	source_path="$(jq -r '.quadlet.sourcePath // empty' <<<"$prior_data")"
	[ -n "$container_unit" ] && [ -n "$source_path" ] || {
		printf 'prior Quadlet unit identity is missing for backend transition of %s\n' \
			"$podman_compose_service_name" >&2
		return 1
	}
	state="$(systemctl --user show \
		--property=LoadState \
		--property=ActiveState \
		--property=SourcePath \
		--property=FragmentPath \
		--value "$container_unit")" || {
		printf 'cannot inspect prior Quadlet unit %s for backend transition\n' "$container_unit" >&2
		return 2
	}
	load_state="$(sed -n '1p' <<<"$state")"
	active_state="$(sed -n '2p' <<<"$state")"
	source_path_actual="$(sed -n '3p' <<<"$state")"
	fragment_path="$(sed -n '4p' <<<"$state")"
	case "${load_state}:${active_state}" in
	not-found:inactive) return 0 ;;
	loaded:inactive)
		[ "$source_path_actual" = "$source_path" ] || return 1
		case "$fragment_path" in
		"$runtime_dir/systemd/generator/$container_unit" | \
			"$runtime_dir/systemd/generator.early/$container_unit" | \
			"$runtime_dir/systemd/generator.late/$container_unit") return 0 ;;
		esac
		;;
	esac
	printf 'prior Quadlet unit is not clean for backend transition of %s (unit=%s load=%s active=%s)\n' \
		"$podman_compose_service_name" "$container_unit" "$load_state" "$active_state" >&2
	return 1
}

backend_transition_quadlet_containers_clean() {
	local matches prior_data state_json
	prior_data="$1"
	if [ "$(jq -r '(.quadlet.labels // {}) | length' <<<"$prior_data")" -eq 0 ]; then
		printf 'prior Quadlet container identity is missing for backend transition of %s\n' \
			"$podman_compose_service_name" >&2
		return 1
	fi
	if ! state_json="$(podman_no_notify ps -a --format json)"; then
		printf 'cannot inspect prior Quadlet containers for backend transition of %s\n' \
			"$podman_compose_service_name" >&2
		return 2
	fi
	matches="$(jq -r --argjson prior "$prior_data" '
		($prior.quadlet.labels // {}) as $expected
		| [.[]
			| (.Labels // {}) as $actual
			| select(all($expected | to_entries[]; $actual[.key] == .value))
			| (.Names[0] // .Name // .Id // .ID // "unknown")]
		| .[]
	' <<<"$state_json")" || return 2
	[ -z "$matches" ] || {
		printf 'prior Quadlet containers remain for backend transition of %s:\n%s\n' \
			"$podman_compose_service_name" "$matches" >&2
		return 1
	}
}

backend_transition_admit() {
	local applied_backend prior_data status
	applied_backend="$(last_applied_backend)"
	[ "$applied_backend" = "$backend" ] && return 0
	prior_data="$(last_applied_backend_data)"
	case "$applied_backend" in
	compose)
		status=0
		backend_transition_compose_runtime_clean || status="$?"
		[ "$status" -eq 0 ] || return "$status"
		;;
	quadlet)
		status=0
		backend_transition_quadlet_unit_clean "$prior_data" || status="$?"
		[ "$status" -eq 0 ] || return "$status"
		backend_transition_quadlet_containers_clean "$prior_data" || status="$?"
		[ "$status" -eq 0 ] || return "$status"
		;;
	*)
		printf 'unknown applied backend %s for transition of %s\n' \
			"$applied_backend" "$podman_compose_service_name" >&2
		return 1
		;;
	esac
	printf 'backend transition admitted for %s: %s -> %s\n' \
		"$podman_compose_service_name" "$applied_backend" "$backend"
}

write_runtime_state_with_filter() {
	local jq_filter tmp_state
	jq_filter="$1"
	install -d -m 0750 "$generated_dir"
	tmp_state="${state_path}.tmp"
	existing_runtime_state_json |
		jq -c \
			--argjson version "$runtime_state_version" \
			--arg kind "$runtime_state_kind" \
			--arg adoptionStamp "$adoption_stamp" \
			"(. + {version: \$version, kind: \$kind, adoptionStamp: \$adoptionStamp}) | ($jq_filter)" >"$tmp_state"
	chmod 0640 "$tmp_state"
	mv -f "$tmp_state" "$state_path"
}

legacy_state_path() {
	printf '%s\n' "$generated_dir/helper-state.json"
}

migrate_legacy_runtime_state_if_needed() {
	local legacy tmp_state
	[ ! -f "$state_path" ] || return 0
	legacy="$(legacy_state_path)"
	[ -f "$legacy" ] || return 0

	install -d -m 0750 "$generated_dir"
	tmp_state="${state_path}.tmp"
	if ! jq -c \
		--argjson version "$runtime_state_version" \
		--arg kind "$runtime_state_kind" \
		--arg adoptionStamp "$adoption_stamp" \
		'{
			version: $version,
			kind: $kind,
			adoptionStamp: $adoptionStamp,
			recreateTag: (.recreateTag // "0"),
			recreateStamp: (.recreateStamp // "")
		}' "$legacy" >"$tmp_state"; then
		rm -f "$tmp_state"
		return 0
	fi
	chmod 0640 "$tmp_state"
	mv -f "$tmp_state" "$state_path"
	rm -f "$legacy"
}

migrate_runtime_state_version_if_needed() {
	local tmp_state
	[ -f "$state_path" ] || return 0
	runtime_state_matches && return 0
	if ! jq -e \
		--arg kind "$runtime_state_kind" \
		--arg adoptionStamp "$adoption_stamp" \
		'(.kind == $kind) and (.adoptionStamp == $adoptionStamp)' \
		"$state_path" >/dev/null 2>&1; then
		return 0
	fi

	tmp_state="${state_path}.tmp"
	if ! jq -c \
		--argjson version "$runtime_state_version" \
		--arg kind "$runtime_state_kind" \
		--arg adoptionStamp "$adoption_stamp" \
		--arg reconcilePolicy "$reconcile_policy" \
		--arg restartStamp "$restart_stamp" \
		'. + {version: $version, kind: $kind, adoptionStamp: $adoptionStamp, reconcilePolicy: $reconcilePolicy, restartStamp: $restartStamp} | del(.startupPhase)' \
		"$state_path" >"$tmp_state"; then
		rm -f "$tmp_state"
		return 0
	fi
	chmod 0640 "$tmp_state"
	mv -f "$tmp_state" "$state_path"
}

last_applied_recreate_tag() {
	runtime_state_field recreateTag "0"
}

last_applied_recreate_stamp() {
	runtime_state_field recreateStamp ""
}

last_applied_recreate_class_stamp() {
	runtime_state_field recreateClassStamp "$(last_applied_recreate_stamp)"
}

last_applied_reconcile_policy() {
	runtime_state_field reconcilePolicy ""
}

last_applied_restart_stamp() {
	runtime_state_field restartStamp ""
}

last_applied_image_pull_stamp() {
	runtime_state_field imagePullStamp ""
}

declared_images_present() {
	local image

	[ "${#declared_images[@]}" -gt 0 ] || return 1
	for image in "${declared_images[@]}"; do
		if ! (
			close_lifecycle_fds_for_child
			podman_no_notify image exists "$image" >/dev/null 2>&1
		); then
			return 1
		fi
	done
}

image_pull_state_current() {
	local applied_image_pull_stamp

	[ -n "$image_pull_stamp" ] || return 1
	migrate_legacy_runtime_state_if_needed
	migrate_runtime_state_version_if_needed
	applied_image_pull_stamp="$(last_applied_image_pull_stamp)"
	[ "$applied_image_pull_stamp" = "$image_pull_stamp" ] || return 1
	declared_images_present
}

record_image_pull_state() {
	local tmp_state
	install -d -m 0750 "$generated_dir"
	tmp_state="${state_path}.tmp"
	existing_runtime_state_json |
		jq -c \
			--argjson version "$runtime_state_version" \
			--arg kind "$runtime_state_kind" \
			--arg adoptionStamp "$adoption_stamp" \
			--arg imagePullStamp "$image_pull_stamp" \
			'. + {version: $version, kind: $kind, adoptionStamp: $adoptionStamp, imagePullStamp: $imagePullStamp} | del(.startupPhase)' >"$tmp_state"
	chmod 0640 "$tmp_state"
	mv -f "$tmp_state" "$state_path"
}

record_image_pull_status() {
	local status
	status="$1"

	if [ -n "$image_pull_status_file" ]; then
		printf '%s\n' "$status" >"$image_pull_status_file"
	fi
}

policy_transition_forces_recreate() {
	local applied_reconcile_policy
	applied_reconcile_policy="$(last_applied_reconcile_policy)"
	[ "$applied_reconcile_policy" = restart ] || return 1
	case "$reconcile_policy" in
	auto | recreate)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

verify_runtime_state_current() {
	local applied_restart_stamp
	if [ "$adopt_existing" = "true" ]; then
		return 0
	fi
	bootstrap_legacy_runtime_state_if_needed
	migrate_runtime_state_version_if_needed
	applied_restart_stamp="$(last_applied_restart_stamp)"
	if [ "$restart_stamp" != "$applied_restart_stamp" ]; then
		printf '%s\n' "podman compose restart-class metadata is not applied for ${podman_compose_service_name}" >&2
		printf '%s\n' "expected restartStamp=$restart_stamp applied restartStamp=$applied_restart_stamp" >&2
		return 1
	fi
	if should_force_recreate; then
		printf '%s\n' "podman compose recreate-class metadata is not applied for ${podman_compose_service_name}" >&2
		return 1
	fi
}

record_runtime_state() {
	local backend_data tmp_state
	install -d -m 0750 "$generated_dir"
	tmp_state="${state_path}.tmp"
	backend_data="$(current_backend_data_json)"
	existing_runtime_state_json |
		jq -c \
			--argjson version "$runtime_state_version" \
			--arg kind "$runtime_state_kind" \
			--arg adoptionStamp "$adoption_stamp" \
			--arg appliedBackend "$backend" \
			--argjson appliedBackendData "$backend_data" \
			--arg reconcilePolicy "$reconcile_policy" \
			--arg restartStamp "$restart_stamp" \
			'. + {version: $version, kind: $kind, adoptionStamp: $adoptionStamp, appliedBackend: $appliedBackend, appliedBackendData: $appliedBackendData, reconcilePolicy: $reconcilePolicy, restartStamp: $restartStamp} | del(.startupPhase)' >"$tmp_state"
	chmod 0640 "$tmp_state"
	mv -f "$tmp_state" "$state_path"
}

record_staging_runtime_state() {
	local tmp_state
	install -d -m 0750 "$generated_dir"
	tmp_state="${state_path}.tmp"
	existing_runtime_state_json |
		jq -c \
			--argjson version "$runtime_state_version" \
			--arg kind "$runtime_state_kind" \
			--arg adoptionStamp "$adoption_stamp" \
			--arg reconcilePolicy "$reconcile_policy" \
			--arg restartStamp "$restart_stamp" \
			'. + {version: $version, kind: $kind, adoptionStamp: $adoptionStamp, reconcilePolicy: $reconcilePolicy, restartStamp: $restartStamp, startupPhase: "staging"}' >"$tmp_state"
	chmod 0640 "$tmp_state"
	mv -f "$tmp_state" "$state_path"
}

record_applied_recreate_state() {
	local backend_data tmp_state
	install -d -m 0750 "$generated_dir"
	tmp_state="${state_path}.tmp"
	backend_data="$(current_backend_data_json)"
	existing_runtime_state_json |
		jq -c \
			--argjson version "$runtime_state_version" \
			--arg kind "$runtime_state_kind" \
			--arg adoptionStamp "$adoption_stamp" \
			--arg appliedBackend "$backend" \
			--argjson appliedBackendData "$backend_data" \
			--arg reconcilePolicy "$reconcile_policy" \
			--arg restartStamp "$restart_stamp" \
			--arg recreateTag "$recreate_tag" \
			--arg recreateStamp "$recreate_stamp" \
			--arg recreateClassStamp "$recreate_class_stamp" \
			'. + {version: $version, kind: $kind, adoptionStamp: $adoptionStamp, appliedBackend: $appliedBackend, appliedBackendData: $appliedBackendData, reconcilePolicy: $reconcilePolicy, restartStamp: $restartStamp, recreateTag: $recreateTag, recreateStamp: $recreateStamp, recreateClassStamp: $recreateClassStamp} | del(.startupPhase)' >"$tmp_state"
	chmod 0640 "$tmp_state"
	mv -f "$tmp_state" "$state_path"
}

# shellcheck disable=SC2016 # jq program; shell expansion happens at use sites.
compose_state_health_filter='def health:
  ((.Health // .HealthStatus // "") | tostring | ascii_downcase) as $health
  | if $health != "" and $health != "<nil>" then $health
    elif ((.Status // "") | test("\\(unhealthy\\)$"; "i")) then "unhealthy"
    elif ((.Status // "") | test("\\(starting\\)$"; "i")) then "starting"
    elif ((.Status // "") | test("\\(healthy\\)$"; "i")) then "healthy"
    else "none"
    end;'

compose_state_terminal_failure_report() {
	jq -r "
		$compose_state_health_filter
		.[]
		| (.State // \"unknown\") as \$state
		| health as \$health
		| select(
			\$state == \"dead\"
			or (\$state == \"exited\" and ((.ExitCode // 1) != 0))
		)
		| \"\\((.Names // [\"<unknown>\"])[0]): state=\\(\$state) health=\\(\$health) exit=\\(.ExitCode // \"n/a\") status=\\(.Status // \"\")\"
	"
}

compose_state_has_pending_health() {
	jq -e "
		$compose_state_health_filter
		any(.[]; health == \"starting\" or health == \"unhealthy\")
	" >/dev/null
}

compose_state_running_count() {
	jq -r '[.[] | select((.State // "") == "running")] | length'
}

compose_state_readiness_signature() {
	jq -cS "
		$compose_state_health_filter
		[
			.[]
			| {
				service: (.Labels[\"io.podman.compose.service\"] // .Labels[\"com.docker.compose.service\"] // ((.Names // [\"\"])[0])),
				state: (.State // \"unknown\"),
				exit: (.ExitCode // null),
				health: health
			}
		]
		| sort_by(.service)
	"
}

compose_state_missing_expected_report() {
	local expected_services_json
	expected_services_json="$(expected_compose_services_json)"
	jq -r --argjson expected "$expected_services_json" '
		def compose_service:
			.Labels["io.podman.compose.service"]
			// .Labels["com.docker.compose.service"]
			// empty;
		($expected - ([.[] | select((.State // "") == "running") | compose_service] | unique))[]?
	'
}

wait_for_compose_state() {
	local require_all state_json signature last_signature="" terminal_failures missing_services
	local started_at now last_progress_at query_failure_since=0 running_count dns_failure_since=0 dns_status
	local readiness_timeout_seconds
	require_all="$1"
	started_at="$(now_epoch)"
	last_progress_at="$started_at"
	readiness_timeout_seconds="$(compose_start_timeout_seconds)"

	while true; do
		now="$(now_epoch)"
		if ! state_json="$(compose_state_json 2>/dev/null)"; then
			if [ "$query_failure_since" -eq 0 ]; then
				query_failure_since="$now"
				printf '%s\n' \
					"podman compose state query is indeterminate for ${podman_compose_service_name};" \
					"retrying within its ${readiness_timeout_seconds}s readiness budget" >&2
			fi
			if [ "$readiness_timeout_seconds" -gt 0 ] &&
				[ "$((now - started_at))" -ge "$readiness_timeout_seconds" ]; then
				printf '%s\n' "podman compose state query failed or timed out for ${podman_compose_service_name} for $((now - query_failure_since))s and exhausted its ${readiness_timeout_seconds}s readiness budget" >&2
				return 1
			fi
			sleep 2
			continue
		fi
		query_failure_since=0

		terminal_failures="$(printf '%s' "$state_json" | compose_state_terminal_failure_report)"
		if [ -n "$terminal_failures" ]; then
			printf '%s\n' "podman compose reached a terminal container state for ${podman_compose_service_name}:" >&2
			printf '%s\n' "$terminal_failures" >&2
			return 1
		fi

		missing_services=""
		if [ "$require_all" = "true" ]; then
			missing_services="$(printf '%s' "$state_json" | compose_state_missing_expected_report)"
		fi
		running_count="$(printf '%s' "$state_json" | compose_state_running_count)"
		if [ "$running_count" -gt 0 ] &&
			[ -z "$missing_services" ] &&
			! printf '%s' "$state_json" | compose_state_has_pending_health; then
			dns_status=0
			if verify_compose_dns_stable; then
				return 0
			else
				dns_status="$?"
			fi
			if [ "$dns_status" -eq "$compose_dns_indeterminate_exit_status" ]; then
				dns_failure_since=0
				sleep 2
				continue
			fi
			if [ "$compose_up_project_dns_reload_attempted" -eq 0 ]; then
				return "$compose_start_project_dns_reloadable_exit_status"
			fi
			if [ "$dns_failure_since" -eq 0 ]; then
				dns_failure_since="$now"
				printf '%s\n' \
					"podman compose peer-service DNS is still converging after in-place project network reload" \
					"for ${podman_compose_service_name}" >&2
			elif [ "$compose_up_no_progress_seconds" -gt 0 ] &&
				[ "$((now - dns_failure_since))" -ge "$compose_up_no_progress_seconds" ]; then
				return "$compose_start_project_dns_reloadable_exit_status"
			fi
			sleep 2
			continue
		fi
		dns_failure_since=0

		signature="$(printf '%s' "$state_json" | compose_state_readiness_signature)"
		if [ "$signature" != "$last_signature" ]; then
			last_signature="$signature"
			last_progress_at="$now"
		elif printf '%s' "$state_json" | compose_state_has_pending_health; then
			# Starting and transiently unhealthy healthchecks are bounded by
			# TimeoutStartSec, not the shorter missing-container no-progress guard.
			last_progress_at="$now"
		elif [ "$compose_up_no_progress_seconds" -gt 0 ] &&
			[ "$((now - last_progress_at))" -ge "$compose_up_no_progress_seconds" ]; then
			printf '%s\n' "podman compose readiness made no state progress for $((now - last_progress_at))s for ${podman_compose_service_name}" >&2
			if [ -n "$missing_services" ]; then
				printf '%s\n' "missing running compose services:" >&2
				printf '%s\n' "$missing_services" >&2
			fi
			return "$compose_start_stuck_exit_status"
		fi
		sleep 2
	done
}

wait_for_compose_readiness() {
	wait_for_compose_state true
}

verify_compose_readiness_with_dns_correction() {
	local status=0
	if [ -f "$compose_dns_correction_marker_path" ]; then
		compose_up_project_dns_reload_attempted=1
	fi
	wait_for_compose_readiness || status="$?"
	[ "$status" -eq "$compose_start_project_dns_reloadable_exit_status" ] || return "$status"
	if [ "$compose_up_project_dns_reload_attempted" -eq 1 ]; then
		printf '%s\n' "podman compose peer-service DNS did not converge after the one project network correction for ${podman_compose_service_name}" >&2
		return "$status"
	fi
	begin_rootless_mutation "compose project DNS correction" || return "$?"
	compose_up_project_dns_reload_attempted=1
	mark_compose_dns_correction_attempted
	if ! reload_compose_project_networks_mutating; then
		leave_rootless_runtime_dirty "project DNS correction failed for ${podman_compose_service_name}"
		return 1
	fi
	commit_rootless_mutation
	wait_for_compose_readiness
}

verify_compose_state_json() {
	local state_json failing_states health_failures state_counts total_count running_count
	state_json="$1"
	failing_states="$(printf '%s' "$state_json" | failing_states_report)"
	health_failures="$(
		printf '%s' "$state_json" |
			jq -r "
				$compose_state_health_filter
				.[]
				| health as \$health
				| select(\$health == \"starting\" or \$health == \"unhealthy\")
				| \"\\((.Names // [\"<unknown>\"])[0]): health=\\(\$health) status=\\(.Status // \"\")\"
			"
	)"

	if [ -n "$failing_states" ]; then
		printf '%s\n' "podman compose left containers in a non-running state:" >&2
		printf '%s\n' "$failing_states" >&2
		return 1
	fi
	if [ -n "$health_failures" ]; then
		printf '%s\n' "podman compose containers are not healthy:" >&2
		printf '%s\n' "$health_failures" >&2
		return 1
	fi

	state_counts="$(
		printf '%s' "$state_json" |
			jq -r '[length, (map(select((.State // "") == "running")) | length)] | @tsv'
	)"
	total_count="$(cut -f1 <<<"$state_counts")"
	running_count="$(cut -f2 <<<"$state_counts")"

	if [ "$total_count" -eq 0 ]; then
		printf '%s\n' "podman compose found no managed containers" >&2
		return 1
	fi

	if [ "$running_count" -eq 0 ] && [ "$long_running" = "true" ]; then
		printf '%s\n' "podman compose found no running containers" >&2
		return 1
	fi

	verify_expected_compose_services
}

verify_compose_state() {
	local state_json
	if ! state_json="$(compose_state_json)"; then
		printf '%s\n' "podman compose state query failed or timed out for ${podman_compose_service_name}" >&2
		return 1
	fi
	verify_compose_state_json "$state_json"
}

monitor_compose_state() {
	local state_json failing_states state_counts total_count running_count
	local monitor_unhealthy_since=0 now elapsed

	monitor_transient_failure() {
		local message details
		message="$1"
		details="${2-}"
		now="$(now_epoch)"
		if [ "$monitor_unhealthy_since" -eq 0 ]; then
			monitor_unhealthy_since="$now"
		fi
		elapsed="$((now - monitor_unhealthy_since))"
		if [ "$elapsed" -lt "$compose_monitor_failure_grace_seconds" ]; then
			printf '%s\n' "${message}; retrying for up to ${compose_monitor_failure_grace_seconds}s before failing ${podman_compose_service_name}" >&2
			if [ -n "$details" ]; then
				printf '%s\n' "$details" >&2
			fi
			return 0
		fi
		printf '%s\n' "$message" >&2
		if [ -n "$details" ]; then
			printf '%s\n' "$details" >&2
		fi
		return 1
	}

	while true; do
		lock_lifecycle_shared
		if start_in_progress_active; then
			monitor_unhealthy_since=0
			unlock_lifecycle_shared
			sleep "$monitor_interval"
			continue
		fi
		if ! state_json="$(compose_state_json)"; then
			if monitor_transient_failure "podman compose monitor state query failed or timed out for ${podman_compose_service_name}"; then
				unlock_lifecycle_shared
				sleep "$monitor_interval"
				continue
			fi
			unlock_lifecycle_shared
			exit 1
		fi
		failing_states="$(printf '%s' "$state_json" | failing_states_report)"

		if [ -n "$failing_states" ]; then
			if monitor_transient_failure "podman compose monitor detected a non-running container state:" "$failing_states"; then
				unlock_lifecycle_shared
				sleep "$monitor_interval"
				continue
			fi
			unlock_lifecycle_shared
			exit 1
		fi

		state_counts="$(
			printf '%s' "$state_json" |
				jq -r '[length, (map(select((.State // "") == "running")) | length)] | @tsv'
		)"
		total_count="$(cut -f1 <<<"$state_counts")"
		running_count="$(cut -f2 <<<"$state_counts")"

		if [ "$total_count" -eq 0 ]; then
			if monitor_transient_failure "podman compose monitor found no managed containers"; then
				unlock_lifecycle_shared
				sleep "$monitor_interval"
				continue
			fi
			unlock_lifecycle_shared
			exit 1
		fi

		if [ "$running_count" -eq 0 ]; then
			if [ "$long_running" = "false" ]; then
				unlock_lifecycle_shared
				exit 0
			fi
			if monitor_transient_failure "podman compose monitor found no running containers"; then
				unlock_lifecycle_shared
				sleep "$monitor_interval"
				continue
			fi
			unlock_lifecycle_shared
			exit 1
		fi

		if ! verify_expected_compose_services; then
			if monitor_transient_failure "podman compose monitor found missing expected services"; then
				unlock_lifecycle_shared
				sleep "$monitor_interval"
				continue
			fi
			unlock_lifecycle_shared
			exit 1
		fi
		if ! verify_compose_dns_stable; then
			if monitor_transient_failure "podman compose monitor found broken compose DNS"; then
				unlock_lifecycle_shared
				sleep "$monitor_interval"
				continue
			fi
			unlock_lifecycle_shared
			exit 1
		fi
		if ! verify_staged_runtime_files_present || ! verify_runtime_state_current; then
			unlock_lifecycle_shared
			exit 1
		fi
		monitor_unhealthy_since=0

		unlock_lifecycle_shared
		sleep "$monitor_interval"
	done
}

cmd_cleanup_files() {
	load_metadata
	lock_lifecycle_exclusive
	cleanup_runtime_files
	unlock_lifecycle_exclusive
}

cmd_link_files() {
	load_metadata
	assert_adoption_allowed
	ensure_runtime_dirs
	lock_lifecycle_exclusive
	record_staging_runtime_state
	stage_runtime_files
	unlock_lifecycle_exclusive
}

cmd_stage() {
	cmd_link_files
}

cmd_bootstrap_internal() {
	load_metadata
	if [ "$desired_state" = "stopped" ]; then
		printf '%s\n' "podman compose instance desired state is stopped; skipping bootstrap"
		return 0
	fi
	run_pre_start_hooks
}

cmd_verify() {
	load_metadata
	while true; do
		if ! wait_for_verify_transition; then
			return 1
		fi
		lock_lifecycle_shared
		if verify_transition_active; then
			unlock_lifecycle_shared
			continue
		fi
		if verify_staged_runtime_files &&
			verify_runtime_state_current &&
			verify_compose_readiness_with_dns_correction &&
			run_verify_command; then
			unlock_lifecycle_shared
			return 0
		fi
		unlock_lifecycle_shared
		return 1
	done
}

cmd_monitor() {
	load_metadata
	monitor_compose_state
}

cmd_reload() {
	local working_dir_exists=0 reload_old_manifest reload_selected_manifest
	load_metadata
	if [ "$desired_state" = "stopped" ]; then
		printf '%s\n' "podman compose instance desired state is stopped; skipping reload"
		return 0
	fi
	[ -d "$working_dir" ] && working_dir_exists=1
	assert_adoption_allowed
	lock_lifecycle_exclusive
	ensure_runtime_dirs
	case "$reload_method" in
	restart)
		begin_rootless_mutation "compose reload down"
		if [ "$working_dir_exists" -eq 1 ]; then
			if ! compose_down; then
				cleanup_failed_compose_stop delete || true
				if ! finish_stop_mutation delete \
					"compose reload teardown postcondition was indeterminate for ${podman_compose_service_name}" rollback; then
					unlock_lifecycle_exclusive
					return 1
				fi
				unlock_lifecycle_exclusive
				return 1
			fi
		fi
		if ! finish_stop_mutation delete \
			"compose reload teardown postcondition was indeterminate for ${podman_compose_service_name}"; then
			unlock_lifecycle_exclusive
			return 1
		fi
		cleanup_runtime_files
		ensure_runtime_dirs
		record_staging_runtime_state
		stage_runtime_files
		if ! compose_start_transaction auto; then
			unlock_lifecycle_exclusive
			return 1
		fi
		if [ "$compose_start_force_recreate" -eq 1 ]; then
			record_applied_recreate_state
		else
			record_runtime_state
		fi
		unlock_lifecycle_exclusive
		if ! run_post_start_hooks; then
			return 1
		fi
		;;
	signal)
		begin_rootless_mutation "compose reload signal"
		reload_old_manifest="${manifest_path}.reload-old.$$"
		reload_selected_manifest="${manifest_path}.reload-selected.$$"
		remove_path_if_exists "$reload_old_manifest"
		remove_path_if_exists "$reload_selected_manifest"
		if ! stage_reload_files "$reload_old_manifest" "$reload_selected_manifest" ||
			! compose_reload_signal ||
			! verify_compose_state; then
			commit_rootless_mutation
			unlock_lifecycle_exclusive
			return 1
		fi
		cleanup_stale_reload_files "$reload_old_manifest" "$reload_selected_manifest"
		write_reload_manifest "$reload_old_manifest" "$reload_selected_manifest" true
		rm -f "$reload_old_manifest" "$reload_selected_manifest"
		commit_rootless_mutation
		;;
	*)
		printf '%s\n' "unsupported podman compose reload method: $reload_method" >&2
		exit 1
		;;
	esac
	unlock_lifecycle_exclusive
}

cmd_start() {
	local status=0
	load_metadata
	assert_adoption_allowed
	ensure_runtime_dirs
	if helper_invoked_as_script && start_in_progress_active; then
		printf '%s\n' "podman compose start is already in progress for ${podman_compose_service_name}; refusing a concurrent lifecycle attempt" >&2
		return "$compose_start_stuck_exit_status"
	fi
	lock_lifecycle_exclusive
	rm -f -- "$failed_start_cleanup_complete_path"
	clear_removal_policy_marker
	record_staging_runtime_state
	stage_runtime_files
	mark_start_in_progress "$$"
	compose_start_transaction auto || {
		status="$?"
		clear_start_in_progress
		unlock_lifecycle_exclusive
		return "$status"
	}
	if [ "$compose_start_force_recreate" -eq 1 ]; then
		record_applied_recreate_state
	else
		record_runtime_state
	fi
	clear_start_in_progress
	unlock_lifecycle_exclusive
	run_post_start_hooks
}

cmd_start_staged() {
	local status=0
	load_metadata
	assert_adoption_allowed
	ensure_runtime_dirs
	if helper_invoked_as_script && start_in_progress_active; then
		printf '%s\n' "podman compose start is already in progress for ${podman_compose_service_name}; refusing a concurrent lifecycle attempt" >&2
		return "$compose_start_stuck_exit_status"
	fi
	lock_lifecycle_exclusive
	rm -f -- "$failed_start_cleanup_complete_path"
	clear_removal_policy_marker
	if ! verify_staged_runtime_files; then
		clear_start_in_progress
		unlock_lifecycle_exclusive
		return 1
	fi
	mark_start_in_progress "$$"
	compose_start_transaction auto || {
		status="$?"
		clear_start_in_progress
		unlock_lifecycle_exclusive
		return "$status"
	}
	if [ "$compose_start_force_recreate" -eq 1 ]; then
		record_applied_recreate_state
	else
		record_runtime_state
	fi
	clear_start_in_progress
	unlock_lifecycle_exclusive
}

cmd_reconcile() {
	load_metadata
	if [ "$desired_state" = "stopped" ]; then
		printf '%s\n' "podman compose instance desired state is stopped; skipping reconcile"
		return 0
	fi
	run_post_start_hooks
}

cmd_repair() {
	cmd_start
}

cmd_stop() {
	local stop_policy cleanup_satisfied_stop=0
	load_metadata
	stop_policy="$(current_stop_policy)"
	lock_lifecycle_exclusive
	mark_stop_in_progress
	if [ "$stop_rootless_lock_timeout_seconds" -gt 0 ]; then
		begin_rootless_mutation_timeout "$stop_rootless_lock_timeout_seconds" "compose stop" drain
	else
		begin_rootless_mutation "compose stop" drain
	fi || {
		printf '%s\n' "podman compose stop failed to acquire rootless mutation lock for ${podman_compose_service_name}; refusing unlocked stop" >&2
		clear_stop_in_progress
		unlock_lifecycle_exclusive
		return 1
	}
	run_pre_stop_hooks || {
		rollback_rootless_mutation_clean
		clear_stop_in_progress
		unlock_lifecycle_exclusive
		return 1
	}
	if ! apply_compose_stop_policy "$stop_policy"; then
		if failed_compose_stop_cleanup_satisfies_stop "$stop_policy"; then
			if cleanup_failed_compose_stop "$stop_policy"; then
				cleanup_satisfied_stop=1
			fi
		else
			cleanup_failed_compose_stop "$stop_policy" || true
		fi
		if ! finish_stop_mutation "$stop_policy" \
			"failed Compose stop for ${podman_compose_service_name}; cleanup postcondition was indeterminate" rollback; then
			cleanup_satisfied_stop=0
		fi
		clear_stop_in_progress
		unlock_lifecycle_exclusive
		if [ "$cleanup_satisfied_stop" -eq 1 ]; then
			return 0
		fi
		return 1
	fi
	if ! finish_stop_mutation "$stop_policy" \
		"Compose stop returned success for ${podman_compose_service_name}, but its postcondition was indeterminate"; then
		clear_stop_in_progress
		unlock_lifecycle_exclusive
		return 1
	fi
	clear_stop_in_progress
	unlock_lifecycle_exclusive
}

cmd_post_stop() {
	local stop_policy failed_start_cleanup=0
	load_metadata
	if post_stop_should_cleanup_failed_start && [ -f "$failed_start_cleanup_complete_path" ]; then
		lock_lifecycle_exclusive
		printf '%s\n' "failed-start cleanup already completed for ${podman_compose_service_name}; skipping post-stop Podman cleanup"
		rm -f -- "$failed_start_cleanup_complete_path"
		clear_start_in_progress
		clear_stop_in_progress
		unlock_lifecycle_exclusive
		return 0
	fi
	if post_stop_should_cleanup_failed_start && ! start_in_progress_marker_active "$start_in_progress_path"; then
		failed_start_cleanup=1
	fi
	if [ "$failed_start_cleanup" -eq 0 ] && [ "${SERVICE_RESULT-success}" = "success" ] && any_compose_start_in_progress_active; then
		printf '%s\n' "podman compose start is in progress; skipping post-stop cleanup for ${podman_compose_service_name}"
		return 0
	fi
	if [ ! -e "$working_dir" ] &&
		[ ! -f "$manifest_path" ] &&
		[ ! -f "$state_path" ] &&
		[ ! -f "$(legacy_state_path)" ]; then
		return 0
	fi
	if [ "$failed_start_cleanup" -eq 0 ] && working_dir_is_uninitialized_helper_shell; then
		return 0
	fi
	stop_policy="$(current_stop_policy)"
	if [ "$failed_start_cleanup" -eq 0 ] && any_compose_start_in_progress_active; then
		printf '%s\n' "podman compose start is in progress; attempting bounded post-stop cleanup for ${podman_compose_service_name}" >&2
		if ! lock_lifecycle_exclusive_timeout "$post_stop_lock_timeout_seconds"; then
			printf '%s\n' "podman compose post-stop timed out waiting for lifecycle lock for ${podman_compose_service_name}; deferring cleanup" >&2
			return 0
		fi
		if ! begin_rootless_mutation_timeout "$post_stop_rootless_lock_timeout_seconds" "compose post-stop cleanup" drain; then
			printf '%s\n' "podman compose post-stop timed out waiting for rootless mutation lock for ${podman_compose_service_name}; deferring cleanup" >&2
			unlock_lifecycle_exclusive
			return 0
		fi
	else
		lock_lifecycle_exclusive
		begin_rootless_mutation "compose post-stop cleanup" drain
	fi
	if [ "$failed_start_cleanup" -eq 1 ]; then
		printf '%s\n' "systemd reported ${podman_compose_service_name}.service result=${SERVICE_RESULT}; running failed-start cleanup"
		cleanup_failed_compose_start
		if ! finish_stop_mutation delete \
			"post-stop failed-start cleanup was indeterminate for ${podman_compose_service_name}" rollback; then
			unlock_lifecycle_exclusive
			return 1
		fi
		unlock_lifecycle_exclusive
		return 0
	elif post_stop_should_cleanup_failed_stop "$stop_policy"; then
		printf '%s\n' "systemd reported ${podman_compose_service_name}.service result=${SERVICE_RESULT}; running failed-stop cleanup"
		cleanup_failed_compose_stop "$stop_policy" || true
	fi
	if ! finish_stop_mutation "$stop_policy" \
		"post-stop cleanup postcondition was indeterminate for ${podman_compose_service_name}"; then
		unlock_lifecycle_exclusive
		return 1
	fi
	if ! apply_compose_post_stop_policy "$stop_policy"; then
		unlock_lifecycle_exclusive
		return 1
	fi
	clear_start_in_progress
	clear_stop_in_progress
	unlock_lifecycle_exclusive
}

cmd_remove() {
	local stop_policy
	load_metadata
	case "$removal_policy" in
	stop | delete | delete-all) ;;
	keep)
		clear_removal_policy_marker
		printf '%s\n' "podman compose removal policy is keep; skipping removal stop"
		return 0
		;;
	*)
		printf '%s\n' "unsupported podman compose removal policy: $removal_policy" >&2
		exit 1
		;;
	esac
	if removal_has_no_staged_runtime; then
		printf '%s\n' "podman compose runtime is already absent; skipping removal stop"
		return 0
	fi
	write_removal_policy_marker
	if ! systemctl --user stop "${podman_compose_service_name}.service"; then
		clear_removal_policy_marker
		return 1
	fi
	if has_removal_policy_marker; then
		if [ ! -f "$manifest_path" ]; then
			clear_removal_policy_marker
			printf '%s\n' "podman compose runtime was already cleaned; skipping removal fallback"
			return 0
		fi
		stop_policy="$(current_stop_policy)"
		lock_lifecycle_exclusive
		begin_rootless_mutation "compose removal cleanup"
		if ! apply_compose_stop_policy "$stop_policy"; then
			cleanup_failed_compose_stop "$stop_policy" || true
		fi
		if ! finish_stop_mutation "$stop_policy" \
			"compose removal cleanup postcondition was indeterminate for ${podman_compose_service_name}"; then
			unlock_lifecycle_exclusive
			clear_removal_policy_marker
			return 1
		fi
		if ! apply_compose_post_stop_policy "$stop_policy"; then
			unlock_lifecycle_exclusive
			clear_removal_policy_marker
			return 1
		fi
		unlock_lifecycle_exclusive
	fi
}

cmd_image_pull() {
	local mutation_rc=0
	load_metadata
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
	begin_image_pull_mutation "compose image pull" || mutation_rc="$?"
	if [ "$mutation_rc" -ne 0 ]; then
		if [ "$image_pull_preflight_policy" = prepare ] && [ "$mutation_rc" -eq 75 ]; then
			record_image_pull_status deferred
			return 0
		fi
		return "$mutation_rc"
	fi
	if ! compose_pull_with_retry; then
		rollback_rootless_mutation_clean
		unlock_lifecycle_exclusive
		return 1
	fi
	commit_rootless_mutation
	record_image_pull_state
	record_image_pull_status pulled
	unlock_lifecycle_exclusive
}

cmd_logs() {
	load_metadata
	if [ ! -f "$manifest_path" ]; then
		printf '%s\n' "podman compose runtime files are not staged for ${podman_compose_service_name}; run 'podman-composectl ${podman_compose_service_name} link' or start the unit before reading logs" >&2
		return 1
	fi
	compose_logs "$@"
}

main() {
	local selected_backend="compose"
	init_vars

	if [ "${1-}" != runtime-preflight ] && [ -n "$podman_compose_metadata" ] && [ -r "$podman_compose_metadata" ]; then
		selected_backend="$(jq -r '.backend // "compose"' "$podman_compose_metadata")"
	fi
	if [ "$selected_backend" = quadlet ]; then
		quadlet_main "$@"
		return
	fi

	case "${1-}" in
	runtime-preflight)
		cmd_runtime_preflight
		;;
	stage)
		cmd_stage
		;;
	bootstrap-internal)
		cmd_bootstrap_internal
		;;
	link-files)
		cmd_link_files
		;;
	cleanup-files)
		cmd_cleanup_files
		;;
	post-stop)
		cmd_post_stop
		;;
	verify)
		cmd_verify
		;;
	monitor)
		cmd_monitor
		;;
	reload)
		cmd_reload
		;;
	repair)
		cmd_repair
		;;
	start-staged)
		cmd_start_staged
		;;
	reconcile)
		cmd_reconcile
		;;
	start)
		cmd_start
		;;
	stop)
		cmd_stop
		;;
	remove)
		cmd_remove
		;;
	image-pull)
		cmd_image_pull
		;;
	logs)
		shift
		cmd_logs "$@"
		;;
	*)
		printf '%s\n' "usage: $0 {runtime-preflight|stage|link-files|cleanup-files|post-stop|verify|monitor|reload|repair|start-staged|reconcile|start|stop|remove|image-pull|logs}" >&2
		exit 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
