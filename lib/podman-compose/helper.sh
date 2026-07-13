#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	podman_compose_metadata="${NIX_PODMAN_COMPOSE_METADATA-}"
	podman_compose_service_name="${NIX_PODMAN_COMPOSE_SERVICE_NAME-}"

	runtime_dir="${XDG_RUNTIME_DIR-}"
	generated_dir=""
	manifest_path=""
	lifecycle_lock_path=""
	start_in_progress_path=""
	stop_in_progress_path=""
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
	compose_up_no_progress_seconds="${NIX_PODMAN_COMPOSE_UP_NO_PROGRESS_SECONDS:-60}"
	compose_start_stuck_exit_status=75
	compose_monitor_timeout_seconds=20
	compose_monitor_failure_grace_seconds=45
	compose_stop_default_timeout_seconds=45
	podman_rootless_lifecycle_lock_depth=0
	post_stop_lock_timeout_seconds="${NIX_PODMAN_COMPOSE_POST_STOP_LOCK_TIMEOUT_SECONDS:-30}"
	post_stop_rootless_lock_timeout_seconds="${NIX_PODMAN_COMPOSE_POST_STOP_ROOTLESS_LOCK_TIMEOUT_SECONDS:-30}"
	stop_rootless_lock_timeout_seconds="${NIX_PODMAN_COMPOSE_STOP_ROOTLESS_LOCK_TIMEOUT_SECONDS:-180}"
	verify_transition_wait_seconds="${NIX_PODMAN_COMPOSE_VERIFY_TRANSITION_WAIT_SECONDS:-30}"
	image_pull_retry_attempts="${NIX_PODMAN_COMPOSE_IMAGE_PULL_RETRY_ATTEMPTS:-10}"
	image_pull_retry_delay_seconds="${NIX_PODMAN_COMPOSE_IMAGE_PULL_RETRY_DELAY_SECONDS:-1}"
	image_pull_status_file="${NIX_PODMAN_COMPOSE_IMAGE_PULL_STATUS_FILE:-}"

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
	podman_network_dns_lock_depth=0
	supervised_active_pid=""
	supervised_active_pid_file=""
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
	desired_state="$(jq -r '.state // "running"' "$podman_compose_metadata")"
	reconcile_policy="$(jq -r '.reconcilePolicy // "auto"' "$podman_compose_metadata")"
	generated_dir="$working_dir/.podman-compose"
	lifecycle_lock_path="$generated_dir/lifecycle.lock"
	start_in_progress_path="$generated_dir/start-in-progress"
	stop_in_progress_path="$generated_dir/stop-in-progress"
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

run_post_start_hooks() {
	run_lifecycle_hooks postStart postStart
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
		cd "$working_dir"
		podman_no_notify_timeout "$compose_monitor_timeout_seconds" compose "${podman_compose_base_args[@]}" "${compose_args[@]}" "${compose_file_args[@]}" ps --format json
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

compose_local_pull_policy_override_file() {
	local override_file tmp_file service sep
	if [ "${#expected_compose_services[@]}" -eq 0 ]; then
		return 0
	fi
	install -d -m 0700 "$generated_dir"
	override_file="$generated_dir/local-pull-policy.override.json"
	tmp_file="$(mktemp "${override_file}.tmp.XXXXXX")"
	{
		printf '{"services":{'
		sep=""
		for service in "${expected_compose_services[@]}"; do
			printf '%s%s:{"pull_policy":"never"}' "$sep" "$(json_string "$service")"
			sep=","
		done
		printf '}}\n'
	} >"$tmp_file"
	mv -f "$tmp_file" "$override_file"
	printf '%s\n' "$override_file"
}

compose_up() {
	local status=0
	podman_rootless_lifecycle_lock
	remove_conflicting_compose_container_names || status="$?"
	podman_rootless_lifecycle_unlock
	if [ "$status" -eq 0 ]; then
		compose_up_supervised normal || status="$?"
	fi
	return "$status"
}

compose_up_force_recreate() {
	local status=0
	podman_rootless_lifecycle_lock
	remove_conflicting_compose_container_names || status="$?"
	if [ "$status" -eq 0 ]; then
		remove_compose_project_containers || status="$?"
	fi
	podman_rootless_lifecycle_unlock
	if [ "$status" -eq 0 ]; then
		# Existing project containers have already been removed above. Avoid
		# podman-compose's --force-recreate path; it can wedge before container
		# creation after image lookup events on rootless Podman.
		compose_up_supervised normal || status="$?"
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

compose_restart_policy_update_timeout_seconds() {
	local timeout_seconds
	timeout_seconds="$(compose_stop_timeout_seconds)"
	if [ "$timeout_seconds" -gt 10 ]; then
		timeout_seconds=10
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
	local mode timeout_seconds reserve_seconds deadline_seconds started_at now line fatal_seen=0 status=0 fatal_status
	local compose_output_fd compose_up_pid compose_up_child_pid compose_up_pid_file
	local state_probe_interval last_state_probe=0 no_progress_since=0 state_json no_progress_report elapsed_no_progress
	local local_pull_policy_override=""
	local -a local_compose_file_args=() up_args=()
	mode="$1"
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
	local_pull_policy_override="$(compose_local_pull_policy_override_file)"
	if [ -n "$local_pull_policy_override" ]; then
		local_compose_file_args+=(-f "$local_pull_policy_override")
	fi
	up_args=(podman compose "${podman_compose_base_args[@]}" "${compose_args[@]}" "${local_compose_file_args[@]}" up --no-build -d --remove-orphans)
	if [ "$mode" = "force" ]; then
		up_args+=(--force-recreate)
	fi
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
						fatal_status="$compose_start_stuck_exit_status"
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

	disable_compose_project_restart_policy_targets "${containers[@]}"
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

disable_container_restart_policy_targets() {
	local update_error
	[ "$#" -gt 0 ] || return 0
	if update_error="$(podman_no_notify_timeout "$(compose_restart_policy_update_timeout_seconds)" update --restart=no "$@" 2>&1)"; then
		[ -n "$update_error" ] && printf '%s\n' "$update_error"
		return 0
	fi
	case "$update_error" in
	*"no such container"* | *"no container with name or ID"*)
		return 0
		;;
	esac
	printf '%s\n' "warning: failed to disable restart policies for ${podman_compose_service_name}: $update_error" >&2
	return 0
}

disable_compose_project_restart_policies() {
	local container targets=()

	while IFS= read -r container; do
		[ -n "$container" ] || continue
		targets+=("$container")
	done < <(compose_project_container_targets)
	disable_compose_project_restart_policy_targets "${targets[@]}"
}

disable_compose_project_restart_policy_targets() {
	[ "$#" -gt 0 ] || return 0
	printf '%s\n' "disabling podman compose restart policies for ${podman_compose_service_name}"
	(
		close_lifecycle_fds_for_child
		disable_container_restart_policy_targets "$@"
	)
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
	printf '%s\n' "podman compose start failed for ${podman_compose_service_name}; cleaning project containers before retry" >&2
	podman_rootless_lifecycle_lock
	if ! compose_down; then
		printf '%s\n' "podman compose down after failed start failed for ${podman_compose_service_name}; attempting direct container removal" >&2
	fi
	if ! remove_compose_project_containers; then
		printf '%s\n' "direct removal of failed podman compose containers also failed for ${podman_compose_service_name}" >&2
	fi
	podman_rootless_lifecycle_unlock
	clear_start_in_progress
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

compose_start_plan_locked() {
	local request status=0
	podman_rootless_lifecycle_lock
	request="$(compose_start_plan)" || status="$?"
	podman_rootless_lifecycle_unlock
	[ "$status" -eq 0 ] || return "$status"
	printf '%s\n' "$request"
}

compose_up_checked() {
	local mode retried=0 status=0
	mode="$1"

	while true; do
		case "$mode" in
		force)
			compose_up_force_recreate
			status="$?"
			if [ "$status" -ne 0 ]; then
				cleanup_failed_compose_start
				if [ "$status" -eq "$compose_start_stuck_exit_status" ]; then
					return "$status"
				fi
				if [ "$retried" -eq 0 ]; then
					retried=1
					restart_aardvark_dns "compose up failed (force)"
					mode=force
					continue
				fi
				return "$status"
			fi
			;;
		normal)
			compose_up
			status="$?"
			if [ "$status" -ne 0 ]; then
				cleanup_failed_compose_start
				if [ "$status" -eq "$compose_start_stuck_exit_status" ]; then
					return "$status"
				fi
				if [ "$retried" -eq 0 ]; then
					retried=1
					restart_aardvark_dns "compose up failed"
					mode=force
					continue
				fi
				return "$status"
			fi
			;;
		*)
			printf '%s\n' "unsupported podman compose up mode: $mode" >&2
			return 1
			;;
		esac

		if ! verify_compose_state; then
			cleanup_failed_compose_start
			if [ "$retried" -eq 0 ]; then
				retried=1
				restart_aardvark_dns "containers failed to reach running state"
				mode=force
				continue
			fi
			return 1
		fi
		if verify_compose_dns; then
			return 0
		fi
		if [ "$retried" -eq 0 ]; then
			retried=1
			restart_aardvark_dns "compose DNS probe failed"
			mode=force
			continue
		fi
		cleanup_failed_compose_start
		return 1
	done
}

compose_down_volumes() {
	local status=0
	disable_compose_project_restart_policies
	compose_command_supervised "down --volumes" "$(compose_stop_timeout_seconds)" podman compose "${podman_compose_base_args[@]}" "${compose_args[@]}" "${compose_file_args[@]}" down --volumes || status="$?"
	return "$status"
}

compose_stop() {
	local status=0
	disable_compose_project_restart_policies
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

podman_network_dns_lock() {
	if [ "$podman_network_dns_lock_depth" -gt 0 ]; then
		podman_network_dns_lock_depth="$((podman_network_dns_lock_depth + 1))"
		return 0
	fi
	install -d -m 0700 "$runtime_dir/podman-compose"
	# v2 avoids live v1 locks leaked into older long-running rootless children.
	exec 7>"$runtime_dir/podman-compose/rootless-network-dns-v2.lock"
	flock -x 7
	podman_network_dns_lock_depth=1
}

podman_network_dns_unlock() {
	if [ "$podman_network_dns_lock_depth" -le 0 ]; then
		return 0
	fi
	podman_network_dns_lock_depth="$((podman_network_dns_lock_depth - 1))"
	if [ "$podman_network_dns_lock_depth" -gt 0 ]; then
		return 0
	fi
	flock -u 7
	exec 7>&-
}

podman_rootless_lifecycle_lock() {
	if [ "$podman_rootless_lifecycle_lock_depth" -gt 0 ]; then
		podman_rootless_lifecycle_lock_depth="$((podman_rootless_lifecycle_lock_depth + 1))"
		return 0
	fi
	install -d -m 0700 "$runtime_dir/podman-compose"
	exec 6>"$runtime_dir/podman-compose/rootless-lifecycle-v1.lock"
	flock -x 6
	podman_rootless_lifecycle_lock_depth=1
}

podman_rootless_lifecycle_lock_timeout() {
	local timeout_seconds
	timeout_seconds="$1"
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
}

podman_rootless_lifecycle_unlock() {
	if [ "$podman_rootless_lifecycle_lock_depth" -le 0 ]; then
		return 0
	fi
	podman_rootless_lifecycle_lock_depth="$((podman_rootless_lifecycle_lock_depth - 1))"
	if [ "$podman_rootless_lifecycle_lock_depth" -gt 0 ]; then
		return 0
	fi
	flock -u 6
	exec 6>&-
}

process_cmdline_contains() {
	local pid needle
	pid="$1"
	needle="$2"

	[ -r "/proc/$pid/cmdline" ] || return 1
	tr '\0' ' ' <"/proc/$pid/cmdline" | grep -Fq -- "$needle"
}

process_uid_matches() {
	local pid uid
	pid="$1"
	uid="$2"

	[ -r "/proc/$pid/status" ] || return 1
	awk -v uid="$uid" '$1 == "Uid:" { found = 1; ok = ($2 == uid) } END { exit !(found && ok) }' "/proc/$pid/status"
}

process_comm_matches() {
	local pid name comm
	pid="$1"
	name="$2"

	[ -r "/proc/$pid/comm" ] || return 1
	read -r comm <"/proc/$pid/comm" || return 1
	[ "$comm" = "$name" ]
}

process_is_aardvark_dns_for_dir() {
	local pid aardvark_dir
	pid="$1"
	aardvark_dir="$2"

	process_comm_matches "$pid" "aardvark-dns" &&
		process_cmdline_contains "$pid" "$aardvark_dir"
}

aardvark_dns_pids_for_dir() {
	local aardvark_dir pid_dir pid
	aardvark_dir="$1"

	for pid_dir in /proc/[0-9]*; do
		[ -d "$pid_dir" ] || continue
		pid="${pid_dir##*/}"
		if process_is_aardvark_dns_for_dir "$pid" "$aardvark_dir"; then
			printf '%s\n' "$pid"
		fi
	done
}

aardvark_dns_pids_for_current_user() {
	local uid pid_dir pid
	uid="$(id -u)"

	for pid_dir in /proc/[0-9]*; do
		[ -d "$pid_dir" ] || continue
		pid="${pid_dir##*/}"
		if process_comm_matches "$pid" "aardvark-dns" &&
			process_uid_matches "$pid" "$uid"; then
			printf '%s\n' "$pid"
		fi
	done
}

read_pid_file() {
	local pid_file pid
	pid_file="$1"

	[ -s "$pid_file" ] || return 1
	read -r pid <"$pid_file" || return 1
	case "$pid" in
	"" | *[!0-9]*)
		return 1
		;;
	esac
	printf '%s\n' "$pid"
}

restart_aardvark_dns() {
	local reason aardvark_dir pid_file pid candidate pids seen killed _
	local running_ids config_file config_name line container_id has_running_entry

	reason="$1"

	[ -n "$runtime_dir" ] || return 0
	aardvark_dir="$runtime_dir/containers/networks/aardvark-dns"
	pid_file="$aardvark_dir/aardvark.pid"
	[ -d "$aardvark_dir" ] || return 0

	podman_network_dns_lock

	# Prune stale aardvark config files (no running container entries) before
	# restarting the daemon so it only loads live network DNS state.
	if running_ids="$(podman_no_notify ps -q --no-trunc 2>/dev/null || true)"; then
		for config_file in "$aardvark_dir"/*; do
			[ -f "$config_file" ] || continue
			config_name="${config_file##*/}"
			[ "$config_name" = "aardvark.pid" ] && continue
			has_running_entry=0
			while IFS= read -r line; do
				container_id="${line%%[[:space:]]*}"
				[ -n "$container_id" ] || continue
				case "$container_id" in *.*.*.*) continue ;; esac
				if grep -Fxq "$container_id" <<<"$running_ids" 2>/dev/null; then
					has_running_entry=1
					break
				fi
			done <"$config_file"
			if [ "$has_running_entry" -eq 0 ]; then
				printf '%s\n' "removing stale podman aardvark DNS config with no running containers for ${podman_compose_service_name}: ${config_file}"
				rm -f -- "$config_file"
			fi
		done
	fi

	pids=""
	seen=""
	killed=0
	if pid="$(read_pid_file "$pid_file")"; then
		if [ -d "/proc/$pid" ] &&
			process_is_aardvark_dns_for_dir "$pid" "$aardvark_dir"; then
			pids="${pids}${pids:+ }${pid}"
		else
			printf '%s\n' "removing stale podman aardvark DNS pid file for ${podman_compose_service_name}: ${pid_file}"
		fi
	else
		printf '%s\n' "podman aardvark DNS has no usable pid file for ${podman_compose_service_name}: ${pid_file}"
	fi

	while IFS= read -r candidate; do
		[ -n "$candidate" ] || continue
		pids="${pids}${pids:+ }${candidate}"
	done < <(aardvark_dns_pids_for_dir "$aardvark_dir")
	while IFS= read -r candidate; do
		[ -n "$candidate" ] || continue
		pids="${pids}${pids:+ }${candidate}"
	done < <(aardvark_dns_pids_for_current_user)

	for pid in $pids; do
		case " $seen " in
		*" $pid "*) continue ;;
		esac
		seen="${seen}${seen:+ }${pid}"
		if [ -d "/proc/$pid" ]; then
			if [ "$killed" -eq 0 ]; then
				printf '%s\n' "restarting podman aardvark DNS for ${podman_compose_service_name}: ${reason}"
			fi
			killed=1
			kill "$pid" 2>/dev/null || true
		fi
	done

	if [ "$killed" -eq 1 ]; then
		for _ in 1 2 3 4 5 6 7 8 9 10; do
			killed=0
			for pid in $seen; do
				if [ -d "/proc/$pid" ]; then
					killed=1
					break
				fi
			done
			[ "$killed" -eq 0 ] && break
			sleep 0.1
		done
		for pid in $seen; do
			if [ -d "/proc/$pid" ]; then
				printf '%s\n' "podman aardvark DNS pid $pid did not exit after TERM; sending KILL"
				kill -KILL "$pid" 2>/dev/null || true
			fi
		done
	fi
	rm -f -- "$pid_file"
	podman_network_dns_unlock
}

compose_dns_probe_pair() {
	local container_id compose_service peer

	[ "$long_running" = "true" ] || return 1
	[ "${#expected_compose_services[@]}" -gt 1 ] || return 1

	while IFS=$'\t' read -r container_id compose_service; do
		[ -n "$container_id" ] || continue
		[ -n "$compose_service" ] || continue
		for peer in "${expected_compose_services[@]}"; do
			[ -n "$peer" ] || continue
			if [ "$peer" != "$compose_service" ]; then
				printf '%s\t%s\t%s\n' "$container_id" "$compose_service" "$peer"
				return 0
			fi
		done
	done < <(
		close_lifecycle_fds_for_child
		cd /
		podman_no_notify ps \
			--filter "label=com.docker.compose.project.working_dir=$working_dir" \
			--format json |
			jq -r '.[] | [.ID, (.Labels["io.podman.compose.service"] // .Labels["com.docker.compose.service"] // "")] | @tsv'
	)
	return 1
}

verify_compose_dns() {
	local pair container_id compose_service peer output status

	if ! pair="$(compose_dns_probe_pair)"; then
		return 0
	fi
	IFS=$'\t' read -r container_id compose_service peer <<<"$pair"

	output="$(
		close_lifecycle_fds_for_child
		cd /
		# shellcheck disable=SC2016 # $1 is expanded by the inner shell.
		timeout 5 env -u NOTIFY_SOCKET -u WATCHDOG_PID -u WATCHDOG_USEC podman exec "$container_id" sh -c '
			if ! command -v getent >/dev/null 2>&1; then
				exit 77
			fi
			getent hosts "$1" >/dev/null
		' sh "$peer" 2>&1
	)" && return 0
	status="$?"
	if [ "$status" -eq 77 ]; then
		printf '%s\n' "podman compose DNS probe skipped for ${podman_compose_service_name}: getent unavailable in ${compose_service}"
		return 0
	fi

	printf '%s\n' "podman compose DNS probe failed for ${podman_compose_service_name}: ${compose_service} cannot resolve ${peer}" >&2
	if [ -n "$output" ]; then
		printf '%s\n' "$output" >&2
	fi
	return 1
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
			'. + {version: $version, kind: $kind, adoptionStamp: $adoptionStamp, reconcilePolicy: $reconcilePolicy, restartStamp: $restartStamp} | del(.startupPhase)' >"$tmp_state"
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
			--arg recreateTag "$recreate_tag" \
			--arg recreateStamp "$recreate_stamp" \
			--arg recreateClassStamp "$recreate_class_stamp" \
			'. + {version: $version, kind: $kind, adoptionStamp: $adoptionStamp, reconcilePolicy: $reconcilePolicy, restartStamp: $restartStamp, recreateTag: $recreateTag, recreateStamp: $recreateStamp, recreateClassStamp: $recreateClassStamp} | del(.startupPhase)' >"$tmp_state"
	chmod 0640 "$tmp_state"
	mv -f "$tmp_state" "$state_path"
}

verify_compose_state() {
	local state_json failing_states state_counts total_count running_count
	if ! state_json="$(compose_state_json)"; then
		printf '%s\n' "podman compose state query failed or timed out for ${podman_compose_service_name}" >&2
		return 1
	fi
	failing_states="$(printf '%s' "$state_json" | failing_states_report)"

	if [ -n "$failing_states" ]; then
		printf '%s\n' "podman compose left containers in a non-running state:" >&2
		printf '%s\n' "$failing_states" >&2
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
		if ! verify_compose_dns; then
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

notify_ready_and_monitor() {
	local status helper_self
	status="$1"
	helper_self="${NIX_PODMAN_COMPOSE_HELPER_SELF:-$0}"
	if [ -n "${NOTIFY_SOCKET-}" ]; then
		systemd-notify \
			--ready \
			--status="$status"
	fi
	exec "$helper_self" monitor
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
	record_runtime_state
	unlock_lifecycle_exclusive
}

cmd_stage() {
	cmd_link_files
}

cmd_bootstrap() {
	load_metadata
	if [ "$desired_state" = "stopped" ]; then
		printf '%s\n' "podman compose instance desired state is stopped; skipping bootstrap"
		return 0
	fi
	assert_adoption_allowed
	lock_lifecycle_exclusive
	if ! verify_staged_runtime_files; then
		unlock_lifecycle_exclusive
		return 1
	fi
	run_pre_start_hooks || {
		unlock_lifecycle_exclusive
		return 1
	}
	unlock_lifecycle_exclusive
}

cmd_verify() {
	local repaired=0
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
			verify_compose_state; then
			unlock_lifecycle_shared
			return 0
		fi
		unlock_lifecycle_shared
		if [ "$repaired" -eq 1 ] || [ "$desired_state" = "stopped" ]; then
			return 1
		fi
		repaired=1
		printf '%s\n' "podman compose runtime is stale for ${podman_compose_service_name}; restarting service before verify" >&2
		systemctl --user restart "${podman_compose_service_name}.service" || return 1
		run_post_start_hooks || return 1
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
		podman_rootless_lifecycle_lock
		if [ "$working_dir_exists" -eq 1 ]; then
			if ! compose_down; then
				podman_rootless_lifecycle_unlock
				unlock_lifecycle_exclusive
				return 1
			fi
		fi
		podman_rootless_lifecycle_unlock
		cleanup_runtime_files
		ensure_runtime_dirs
		record_staging_runtime_state
		stage_runtime_files
		compose_pull || true
		run_pre_start_hooks || {
			unlock_lifecycle_exclusive
			return 1
		}
		if ! compose_up_checked normal; then
			unlock_lifecycle_exclusive
			return 1
		fi
		unlock_lifecycle_exclusive
		if ! run_post_start_hooks; then
			return 1
		fi
		lock_lifecycle_exclusive
		record_runtime_state
		unlock_lifecycle_exclusive
		;;
	signal)
		podman_rootless_lifecycle_lock
		reload_old_manifest="${manifest_path}.reload-old.$$"
		reload_selected_manifest="${manifest_path}.reload-selected.$$"
		remove_path_if_exists "$reload_old_manifest"
		remove_path_if_exists "$reload_selected_manifest"
		if ! stage_reload_files "$reload_old_manifest" "$reload_selected_manifest" ||
			! compose_reload_signal ||
			! verify_compose_state; then
			podman_rootless_lifecycle_unlock
			unlock_lifecycle_exclusive
			return 1
		fi
		cleanup_stale_reload_files "$reload_old_manifest" "$reload_selected_manifest"
		write_reload_manifest "$reload_old_manifest" "$reload_selected_manifest" true
		rm -f "$reload_old_manifest" "$reload_selected_manifest"
		podman_rootless_lifecycle_unlock
		;;
	*)
		printf '%s\n' "unsupported podman compose reload method: $reload_method" >&2
		exit 1
		;;
	esac
	unlock_lifecycle_exclusive
}

cmd_start() {
	local force_recreate=0 mode=normal request
	load_metadata
	assert_adoption_allowed
	ensure_runtime_dirs
	if helper_invoked_as_script && start_in_progress_active; then
		notify_ready_and_monitor "podman compose start already in progress"
		return 0
	fi
	lock_lifecycle_exclusive
	clear_removal_policy_marker
	record_staging_runtime_state
	stage_runtime_files
	run_pre_start_hooks || {
		clear_start_in_progress
		unlock_lifecycle_exclusive
		return 1
	}
	compose_pull || true
	request="$(compose_start_plan_locked)"
	IFS=$'\t' read -r mode force_recreate <<<"$request"
	mark_start_in_progress "$$"
	unlock_lifecycle_exclusive
	if ! compose_up_checked "$mode"; then
		return 1
	fi
	if ! run_post_start_hooks; then
		return 1
	fi
	lock_lifecycle_exclusive
	if [ "$force_recreate" -eq 1 ]; then
		record_applied_recreate_state
	else
		record_runtime_state
	fi
	clear_start_in_progress
	unlock_lifecycle_exclusive
	notify_ready_and_monitor "podman compose running"
}

cmd_start_staged() {
	local force_recreate=0 mode=normal request
	load_metadata
	assert_adoption_allowed
	ensure_runtime_dirs
	if helper_invoked_as_script && start_in_progress_active; then
		notify_ready_and_monitor "podman compose start already in progress"
		return 0
	fi
	lock_lifecycle_exclusive
	clear_removal_policy_marker
	if ! verify_staged_runtime_files; then
		clear_start_in_progress
		unlock_lifecycle_exclusive
		return 1
	fi
	if ! load_local_images; then
		clear_start_in_progress
		unlock_lifecycle_exclusive
		return 1
	fi
	request="$(compose_start_plan_locked)"
	IFS=$'\t' read -r mode force_recreate <<<"$request"
	mark_start_in_progress "$$"
	unlock_lifecycle_exclusive
	if ! compose_up_checked "$mode"; then
		return 1
	fi
	lock_lifecycle_exclusive
	if [ "$force_recreate" -eq 1 ]; then
		record_applied_recreate_state
	else
		record_runtime_state
	fi
	clear_start_in_progress
	unlock_lifecycle_exclusive
	notify_ready_and_monitor "podman compose running"
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
	run_pre_stop_hooks || {
		clear_stop_in_progress
		unlock_lifecycle_exclusive
		return 1
	}
	if ! podman_rootless_lifecycle_lock_timeout "$stop_rootless_lock_timeout_seconds"; then
		printf '%s\n' "podman compose stop timed out waiting for rootless lifecycle lock for ${podman_compose_service_name}; proceeding with direct stop" >&2
	fi
	if ! apply_compose_stop_policy "$stop_policy"; then
		if failed_compose_stop_cleanup_satisfies_stop "$stop_policy"; then
			if cleanup_failed_compose_stop "$stop_policy"; then
				cleanup_satisfied_stop=1
			fi
		else
			cleanup_failed_compose_stop "$stop_policy" || true
		fi
		podman_rootless_lifecycle_unlock
		clear_stop_in_progress
		unlock_lifecycle_exclusive
		if [ "$cleanup_satisfied_stop" -eq 1 ]; then
			return 0
		fi
		return 1
	fi
	podman_rootless_lifecycle_unlock
	clear_stop_in_progress
	unlock_lifecycle_exclusive
}

cmd_post_stop() {
	local stop_policy failed_start_cleanup=0
	load_metadata
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
		if ! podman_rootless_lifecycle_lock_timeout "$post_stop_rootless_lock_timeout_seconds"; then
			printf '%s\n' "podman compose post-stop timed out waiting for rootless lifecycle lock for ${podman_compose_service_name}; deferring cleanup" >&2
			unlock_lifecycle_exclusive
			return 0
		fi
	else
		lock_lifecycle_exclusive
		podman_rootless_lifecycle_lock
	fi
	if [ "$failed_start_cleanup" -eq 1 ]; then
		printf '%s\n' "systemd reported ${podman_compose_service_name}.service result=${SERVICE_RESULT}; running failed-start cleanup"
		cleanup_failed_compose_start
		podman_rootless_lifecycle_unlock
		unlock_lifecycle_exclusive
		return 0
	elif post_stop_should_cleanup_failed_stop "$stop_policy"; then
		printf '%s\n' "systemd reported ${podman_compose_service_name}.service result=${SERVICE_RESULT}; running failed-stop cleanup"
		cleanup_failed_compose_stop "$stop_policy" || true
	fi
	if ! apply_compose_post_stop_policy "$stop_policy"; then
		podman_rootless_lifecycle_unlock
		unlock_lifecycle_exclusive
		return 1
	fi
	clear_start_in_progress
	clear_stop_in_progress
	podman_rootless_lifecycle_unlock
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
		podman_rootless_lifecycle_lock
		if ! apply_compose_stop_policy "$stop_policy" ||
			! apply_compose_post_stop_policy "$stop_policy"; then
			podman_rootless_lifecycle_unlock
			unlock_lifecycle_exclusive
			clear_removal_policy_marker
			return 1
		fi
		podman_rootless_lifecycle_unlock
		unlock_lifecycle_exclusive
	fi
}

cmd_image_pull() {
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
	lock_lifecycle_exclusive
	if ! compose_pull_with_retry; then
		unlock_lifecycle_exclusive
		return 1
	fi
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
	init_vars

	case "${1-}" in
	stage)
		cmd_stage
		;;
	bootstrap)
		cmd_bootstrap
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
		printf '%s\n' "usage: $0 {stage|bootstrap|link-files|cleanup-files|post-stop|verify|monitor|reload|repair|start-staged|reconcile|start|stop|remove|image-pull|logs}" >&2
		exit 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
