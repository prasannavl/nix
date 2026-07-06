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
	runtime_state_version=1
	runtime_state_kind="podman-compose-runtime-state"
	adoption_stamp=""
	working_dir=""
	desired_state="running"
	reconcile_policy="auto"
	removal_policy="delete"
	adopt_existing="false"
	recreate_tag="0"
	recreate_stamp=""
	recreate_class_stamp=""
	long_running="true"
	reload_method="restart"
	reload_signal="HUP"
	restart_stamp=""
	monitor_interval=10
	podman_network_dns_repaired=0
	compose_start_default_timeout_seconds=900
	compose_start_idle_timeout_seconds=45
	compose_stop_default_timeout_seconds=180

	compose_args=()
	compose_file_args=()
	pull_compose_file_args=()
	expected_compose_services=()
	reload_services=()
	podman_network_dns_lock_depth=0
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
	exec 7>&- 2>/dev/null || true
	exec 8>&- 2>/dev/null || true
	exec 9>&- 2>/dev/null || true
}

podman_no_notify() {
	env -u NOTIFY_SOCKET -u WATCHDOG_PID -u WATCHDOG_USEC podman "$@"
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

run_pre_start_hooks() {
	run_lifecycle_hooks preStart preStart
}

run_pre_stop_hooks() {
	run_lifecycle_hooks preStop preStop
}

adoption_state_matches() {
	[ -n "$adoption_stamp" ] || return 1
	[ -f "$state_path" ] || return 1
	runtime_state_matches
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

	if adoption_state_matches; then
		return 0
	fi

	if working_dir_is_uninitialized_helper_shell; then
		printf '%s\n' "Recovering uninitialized Podman compose helper working directory: $working_dir"
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

compose_state_json() {
	(
		close_lifecycle_fds_for_child
		cd "$working_dir"
		podman_no_notify compose "${compose_args[@]}" "${compose_file_args[@]}" ps --format json
	)
}

compose_up() {
	local status=0
	podman_network_dns_lock
	remove_conflicting_compose_container_names || status="$?"
	if [ "$status" -eq 0 ]; then
		compose_up_supervised normal || status="$?"
	fi
	podman_network_dns_unlock
	return "$status"
}

compose_up_force_recreate() {
	local status=0
	podman_network_dns_lock
	remove_conflicting_compose_container_names || status="$?"
	if [ "$status" -eq 0 ]; then
		remove_compose_project_containers || status="$?"
	fi
	if [ "$status" -eq 0 ]; then
		compose_up_supervised force || status="$?"
	fi
	podman_network_dns_unlock
	return "$status"
}

compose_up_fatal_line() {
	local line
	line="$1"
	grep -Eq \
		'container name ".*" is already in use|cannot be used as a dependency|rootlessport listen tcp .* bind:|aardvark-dns failed to start|failed to bind udp listener .*:53|(^|[[:space:]])image pull-error[[:space:]]' \
		<<<"$line"
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
	local property default_seconds timeout_value timeout_seconds
	property="$1"
	default_seconds="$2"
	timeout_value="$(systemctl --user show --property="$property" --value "${podman_compose_service_name}.service" 2>/dev/null || true)"
	timeout_seconds="$(parse_systemd_timespan_seconds "$timeout_value")"
	if [ "$timeout_seconds" -le 0 ]; then
		timeout_seconds="$default_seconds"
	fi
	printf '%s\n' "$timeout_seconds"
}

compose_start_timeout_seconds() {
	compose_unit_timeout_seconds TimeoutStartUSec "$compose_start_default_timeout_seconds"
}

compose_stop_timeout_seconds() {
	compose_unit_timeout_seconds TimeoutStopUSec "$compose_stop_default_timeout_seconds"
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

compose_command_supervised() {
	local label timeout_seconds reserve_seconds deadline_seconds started_at now line timeout_seen=0 status=0
	local compose_output_fd compose_pid compose_child_pid compose_pid_file
	label="$1"
	timeout_seconds="$2"
	shift 2

	reserve_seconds="$(compose_cleanup_reserve_seconds "$timeout_seconds")"
	started_at="$(now_epoch)"
	deadline_seconds="$((started_at + timeout_seconds - reserve_seconds))"
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

	while true; do
		if IFS= read -r -t 1 -u "$compose_output_fd" line 2>/dev/null; then
			printf '%s\n' "$line"
			continue
		fi

		now="$(now_epoch)"
		if [ "$now" -ge "$deadline_seconds" ]; then
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
	rm -f "$compose_pid_file"

	if [ "$timeout_seen" -eq 1 ]; then
		return 1
	fi
	return "$status"
}

compose_up_supervised() {
	local mode timeout_seconds reserve_seconds deadline_seconds started_at last_progress_at now line fatal_seen=0 status=0
	local compose_output_fd compose_up_pid compose_up_child_pid compose_up_pid_file
	local -a up_args=()
	mode="$1"
	timeout_seconds="$(compose_start_timeout_seconds)"
	reserve_seconds="$(compose_cleanup_reserve_seconds "$timeout_seconds")"
	started_at="$(now_epoch)"
	last_progress_at="$started_at"
	deadline_seconds="$((started_at + timeout_seconds - reserve_seconds))"

	up_args=(podman compose "${compose_args[@]}" "${compose_file_args[@]}" up -d --remove-orphans)
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

	while true; do
		if IFS= read -r -t 1 -u "$compose_output_fd" line 2>/dev/null; then
			last_progress_at="$(now_epoch)"
			printf '%s\n' "$line"
			if compose_up_fatal_line "$line"; then
				fatal_seen=1
				printf '%s\n' "podman compose start hit fatal output for ${podman_compose_service_name}; terminating early" >&2
				compose_up_child_pid="$(supervised_child_pid "$compose_up_pid" "$compose_up_pid_file")"
				terminate_compose_process "$compose_up_child_pid"
				break
			fi
			continue
		fi

		now="$(now_epoch)"
		if [ "$now" -ge "$deadline_seconds" ]; then
			printf '%s\n' "podman compose start exceeded helper deadline for ${podman_compose_service_name}; reserving ${reserve_seconds}s for cleanup before systemd timeout" >&2
			compose_up_child_pid="$(supervised_child_pid "$compose_up_pid" "$compose_up_pid_file")"
			terminate_compose_process "$compose_up_child_pid"
			fatal_seen=1
			break
		fi
		if [ "$compose_start_idle_timeout_seconds" -gt 0 ] &&
			[ "$now" -ge "$((last_progress_at + compose_start_idle_timeout_seconds))" ]; then
			printf '%s\n' "podman compose start made no output progress for ${compose_start_idle_timeout_seconds}s for ${podman_compose_service_name}; treating as a stuck start and retrying" >&2
			compose_up_child_pid="$(supervised_child_pid "$compose_up_pid" "$compose_up_pid_file")"
			terminate_compose_process "$compose_up_child_pid"
			fatal_seen=1
			break
		fi

		if ! kill -0 "$compose_up_pid" 2>/dev/null; then
			break
		fi
	done

	while IFS= read -r -t 0.1 -u "$compose_output_fd" line 2>/dev/null; do
		printf '%s\n' "$line"
	done

	wait "$compose_up_pid" || status="$?"
	exec {compose_output_fd}<&- 2>/dev/null || true
	rm -f "$compose_up_pid_file"

	if [ "$fatal_seen" -eq 1 ]; then
		return 1
	fi
	return "$status"
}

compose_down() {
	local status=0
	podman_network_dns_lock
	disable_compose_project_restart_policies
	compose_command_supervised down "$(compose_stop_timeout_seconds)" podman compose "${compose_args[@]}" "${compose_file_args[@]}" down || status="$?"
	podman_network_dns_unlock
	return "$status"
}

compose_project_container_ids() {
	(
		close_lifecycle_fds_for_child
		cd /
		podman_no_notify ps -a \
			--filter "label=com.docker.compose.project.working_dir=$working_dir" \
			--format '{{.ID}}'
	)
}

compose_project_container_names() {
	local compose_project compose_service
	compose_project="$(basename "$working_dir")"
	for compose_service in "${expected_compose_services[@]}"; do
		[ -n "$compose_service" ] || continue
		printf '%s\n' "${compose_project}_${compose_service}_1"
	done
}

container_compose_working_dir_label() {
	local container
	container="$1"
	podman_no_notify inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' "$container" 2>/dev/null || true
}

remove_conflicting_compose_container_names() {
	local container label volume failed=0 anonymous_volumes=()

	while IFS= read -r container; do
		[ -n "$container" ] || continue
		if ! podman_no_notify container exists "$container"; then
			continue
		fi
		label="$(container_compose_working_dir_label "$container")"
		if [ "$label" = "$working_dir" ]; then
			continue
		fi
		printf '%s\n' "removing conflicting podman compose container name for ${podman_compose_service_name}: ${container}"
		while IFS= read -r volume; do
			[ -n "$volume" ] || continue
			anonymous_volumes+=("$volume")
		done < <(container_anonymous_volume_names "$container")
		remove_container_target "$container" || failed=1
	done < <(compose_project_container_names)

	for volume in "${anonymous_volumes[@]}"; do
		remove_anonymous_volume_target "$volume" || failed=1
	done

	return "$failed"
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

remove_container_target() {
	local target remove_error cleanup_error
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
	*"no such container"* | *"no container with name or ID"*)
		return 0
		;;
	esac
	if cleanup_error="$(podman_no_notify container cleanup --rm "$target" 2>&1)"; then
		[ -n "$cleanup_error" ] && printf '%s\n' "$cleanup_error"
		if ! podman_no_notify container exists "$target"; then
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

disable_container_restart_policy_target() {
	local target update_error
	target="$1"
	if update_error="$(podman_no_notify update --restart=no "$target" 2>&1)"; then
		[ -n "$update_error" ] && printf '%s\n' "$update_error"
		return 0
	fi
	case "$update_error" in
	*"no such container"* | *"no container with name or ID"*)
		return 0
		;;
	esac
	printf '%s\n' "warning: failed to disable restart policy for $target: $update_error" >&2
	return 0
}

disable_compose_project_restart_policies() {
	local container containers=() container_names=()

	while IFS= read -r container; do
		[ -n "$container" ] || continue
		containers+=("$container")
	done < <(compose_project_container_ids)

	while IFS= read -r container; do
		[ -n "$container" ] || continue
		container_names+=("$container")
	done < <(compose_project_container_names)

	[ "${#containers[@]}" -gt 0 ] || [ "${#container_names[@]}" -gt 0 ] || return 0
	printf '%s\n' "disabling podman compose restart policies for ${podman_compose_service_name}"
	(
		close_lifecycle_fds_for_child
		for container in "${containers[@]}" "${container_names[@]}"; do
			disable_container_restart_policy_target "$container"
		done
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

remove_compose_project_containers() {
	local container volume failed=0 containers=() container_names=() anonymous_volumes=()

	while IFS= read -r container; do
		[ -n "$container" ] || continue
		containers+=("$container")
	done < <(compose_project_container_ids)

	while IFS= read -r container; do
		[ -n "$container" ] || continue
		container_names+=("$container")
	done < <(compose_project_container_names)

	[ "${#containers[@]}" -gt 0 ] || [ "${#container_names[@]}" -gt 0 ] || return 0
	printf '%s\n' "removing stale podman compose containers for ${podman_compose_service_name}"
	(
		close_lifecycle_fds_for_child
		for container in "${containers[@]}" "${container_names[@]}"; do
			while IFS= read -r volume; do
				[ -n "$volume" ] || continue
				anonymous_volumes+=("$volume")
			done < <(container_anonymous_volume_names "$container")
		done
		for container in "${containers[@]}" "${container_names[@]}"; do
			remove_container_target "$container" || failed=1
		done
		for volume in "${anonymous_volumes[@]}"; do
			remove_anonymous_volume_target "$volume" || failed=1
		done
		return "$failed"
	)
}

cleanup_failed_compose_start() {
	printf '%s\n' "podman compose start failed for ${podman_compose_service_name}; cleaning project containers before retry" >&2
	if ! compose_down; then
		printf '%s\n' "podman compose down after failed start failed for ${podman_compose_service_name}; attempting direct container removal" >&2
	fi
	if ! remove_compose_project_containers; then
		printf '%s\n' "direct removal of failed podman compose containers also failed for ${podman_compose_service_name}" >&2
	fi
	cleanup_runtime_files
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

mark_start_in_progress() {
	install -d -m 0750 "$generated_dir"
	{
		printf 'pid=%s\n' "$$"
		printf 'startedAt=%s\n' "$(now_epoch)"
	} >"${start_in_progress_path}.tmp"
	mv -f "${start_in_progress_path}.tmp" "$start_in_progress_path"
}

clear_start_in_progress() {
	rm -f -- "$start_in_progress_path" "${start_in_progress_path}.tmp"
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

compose_up_checked() {
	local mode dns_retried=0
	mode="$1"

	while true; do
		case "$mode" in
		force)
			if ! compose_up_force_recreate; then
				cleanup_failed_compose_start
				return 1
			fi
			;;
		normal)
			if ! compose_up; then
				cleanup_failed_compose_start
				return 1
			fi
			;;
		*)
			printf '%s\n' "unsupported podman compose up mode: $mode" >&2
			return 1
			;;
		esac

		if ! verify_compose_state; then
			cleanup_failed_compose_start
			return 1
		fi
		if verify_compose_dns; then
			return 0
		fi
		if [ "$dns_retried" -eq 1 ]; then
			cleanup_failed_compose_start
			return 1
		fi
		dns_retried=1
		restart_aardvark_dns "compose DNS probe failed"
		mode=force
	done
}

compose_down_volumes() {
	local status=0
	podman_network_dns_lock
	disable_compose_project_restart_policies
	compose_command_supervised "down --volumes" "$(compose_stop_timeout_seconds)" podman compose "${compose_args[@]}" "${compose_file_args[@]}" down --volumes || status="$?"
	podman_network_dns_unlock
	return "$status"
}

compose_stop() {
	local status=0
	podman_network_dns_lock
	disable_compose_project_restart_policies
	compose_command_supervised stop "$(compose_stop_timeout_seconds)" podman compose "${compose_args[@]}" "${compose_file_args[@]}" stop || status="$?"
	podman_network_dns_unlock
	return "$status"
}

compose_pull() {
	(
		close_lifecycle_fds_for_child
		cd "$working_dir"
		podman_no_notify compose "${compose_args[@]}" "${pull_compose_file_args[@]}" pull 2>&1
	)
}

compose_logs() {
	(
		close_lifecycle_fds_for_child
		cd "$working_dir"
		podman_no_notify compose "${compose_args[@]}" "${compose_file_args[@]}" logs "$@"
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

mark_podman_network_dns_repaired() {
	podman_network_dns_repaired=1
}

restart_aardvark_dns() {
	local reason aardvark_dir pid_file pid candidate pids seen killed _
	reason="$1"

	[ -n "$runtime_dir" ] || return 0
	aardvark_dir="$runtime_dir/containers/networks/aardvark-dns"
	pid_file="$aardvark_dir/aardvark.pid"
	[ -d "$aardvark_dir" ] || return 0

	podman_network_dns_lock
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
	mark_podman_network_dns_repaired
	podman_network_dns_unlock
}

repair_stale_aardvark_dns_pid() {
	local aardvark_dir pid_file pid matching_pids matching_count

	[ -n "$runtime_dir" ] || return 0
	aardvark_dir="$runtime_dir/containers/networks/aardvark-dns"
	pid_file="$aardvark_dir/aardvark.pid"
	[ -d "$aardvark_dir" ] || return 0
	matching_pids="$(aardvark_dns_pids_for_dir "$aardvark_dir" || true)"
	matching_count="$(grep -c . <<<"$matching_pids" || true)"

	if pid="$(read_pid_file "$pid_file")" &&
		[ -d "/proc/$pid" ] &&
		process_is_aardvark_dns_for_dir "$pid" "$aardvark_dir"; then
		if [ "$matching_count" -le 1 ]; then
			return 0
		fi
		restart_aardvark_dns "duplicate aardvark DNS processes"
		return 0
	fi

	if [ -e "$pid_file" ]; then
		restart_aardvark_dns "stale pid file"
	elif [ -n "$matching_pids" ]; then
		restart_aardvark_dns "missing pid file"
	fi
}

repair_stale_aardvark_dns_config_files() {
	local aardvark_dir running_ids config_file config_name line container_id has_running_entry removed=0

	[ -n "$runtime_dir" ] || return 0
	aardvark_dir="$runtime_dir/containers/networks/aardvark-dns"
	[ -d "$aardvark_dir" ] || return 0

	if ! running_ids="$(podman_no_notify ps -q --no-trunc)"; then
		return 0
	fi

	for config_file in "$aardvark_dir"/*; do
		[ -f "$config_file" ] || continue
		config_name="${config_file##*/}"
		case "$config_name" in
		aardvark.pid) continue ;;
		esac

		has_running_entry=0
		while IFS= read -r line; do
			container_id="${line%%[[:space:]]*}"
			[ -n "$container_id" ] || continue
			case "$container_id" in
			*.*.*.*) continue ;;
			esac
			if grep -Fxq "$container_id" <<<"$running_ids"; then
				has_running_entry=1
				break
			fi
		done <"$config_file"

		if [ "$has_running_entry" -eq 0 ]; then
			printf '%s\n' "removing stale podman aardvark DNS config with no running containers for ${podman_compose_service_name}: ${config_file}"
			rm -f -- "$config_file"
			removed=1
		fi
	done

	if [ "$removed" -eq 1 ]; then
		restart_aardvark_dns "stale DNS config file"
	fi
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

rootless_netns_has_live_connection() {
	local netns_dir pid_file pid
	netns_dir="$1"
	pid_file="$netns_dir/rootless-netns-conn.pid"

	[ -s "$pid_file" ] || return 1
	read -r pid <"$pid_file" || return 1
	case "$pid" in
	"" | *[!0-9]*)
		return 1
		;;
	esac
	[ -d "/proc/$pid" ]
}

repair_stale_rootless_netns_resolver() {
	local netns_dir resolved_stub netns_resolved_stub running_containers

	[ -n "$runtime_dir" ] || return 0
	netns_dir="$runtime_dir/containers/networks/rootless-netns"
	resolved_stub="/run/systemd/resolve/stub-resolv.conf"
	netns_resolved_stub="$netns_dir/run/systemd/resolve/stub-resolv.conf"

	[ -d "$netns_dir" ] || return 0
	[ -e "$resolved_stub" ] || return 0
	[ ! -e "$netns_resolved_stub" ] || return 0

	if running_containers="$(podman_no_notify ps -q)"; then
		if [ -n "$running_containers" ]; then
			printf '%s\n' "podman rootless netns resolver state is stale but containers are running; leaving $netns_dir unchanged"
			return 0
		fi
	elif rootless_netns_has_live_connection "$netns_dir"; then
		printf '%s\n' "podman rootless netns resolver state is stale but namespace connection is live; leaving $netns_dir unchanged"
		return 0
	fi

	printf '%s\n' "removing stale inactive podman rootless netns resolver state: $netns_dir"
	rm -rf -- "$netns_dir"
	mark_podman_network_dns_repaired
}

repair_podman_rootless_dns_state() {
	local status=0
	podman_network_dns_lock
	repair_stale_aardvark_dns_pid
	repair_stale_aardvark_dns_config_files
	repair_stale_rootless_netns_resolver || status="$?"
	podman_network_dns_unlock
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
		podman_no_notify compose "${compose_args[@]}" "${compose_file_args[@]}" kill --signal "$reload_signal" "${reload_services[@]}" 2>&1
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
	state_json="$(compose_state_json)"
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
	while true; do
		lock_lifecycle_shared
		state_json="$(compose_state_json)"
		failing_states="$(printf '%s' "$state_json" | failing_states_report)"

		if [ -n "$failing_states" ]; then
			printf '%s\n' "podman compose monitor detected a non-running container state:" >&2
			printf '%s\n' "$failing_states" >&2
			exit 1
		fi

		state_counts="$(
			printf '%s' "$state_json" |
				jq -r '[length, (map(select((.State // "") == "running")) | length)] | @tsv'
		)"
		total_count="$(cut -f1 <<<"$state_counts")"
		running_count="$(cut -f2 <<<"$state_counts")"

		if [ "$total_count" -eq 0 ]; then
			printf '%s\n' "podman compose monitor found no managed containers" >&2
			exit 1
		fi

		if [ "$running_count" -eq 0 ]; then
			if [ "$long_running" = "false" ]; then
				exit 0
			fi
			printf '%s\n' "podman compose monitor found no running containers" >&2
			exit 1
		fi

		verify_expected_compose_services
		if ! verify_staged_runtime_files || ! verify_runtime_state_current; then
			exit 1
		fi

		unlock_lifecycle_shared
		sleep "$monitor_interval"
	done
}

notify_ready_and_monitor() {
	local status
	status="$1"
	if [ -n "${NOTIFY_SOCKET-}" ]; then
		exec systemd-notify \
			--ready \
			--status="$status" \
			--exec ';' -- \
			"$0" monitor
	fi
	exec "$0" monitor
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

cmd_verify() {
	load_metadata
	lock_lifecycle_shared
	if ! verify_staged_runtime_files ||
		! verify_runtime_state_current ||
		! verify_compose_state; then
		unlock_lifecycle_shared
		return 1
	fi
	unlock_lifecycle_shared
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
		if [ "$working_dir_exists" -eq 1 ]; then
			compose_down
		fi
		cleanup_runtime_files
		ensure_runtime_dirs
		record_staging_runtime_state
		stage_runtime_files
		repair_podman_rootless_dns_state
		run_pre_start_hooks || {
			unlock_lifecycle_exclusive
			return 1
		}
		if [ "$podman_network_dns_repaired" -eq 1 ]; then
			compose_up_checked force
		else
			compose_up_checked normal
		fi
		record_runtime_state
		;;
	signal)
		reload_old_manifest="${manifest_path}.reload-old.$$"
		reload_selected_manifest="${manifest_path}.reload-selected.$$"
		remove_path_if_exists "$reload_old_manifest"
		remove_path_if_exists "$reload_selected_manifest"
		stage_reload_files "$reload_old_manifest" "$reload_selected_manifest"
		compose_reload_signal
		verify_compose_state
		cleanup_stale_reload_files "$reload_old_manifest" "$reload_selected_manifest"
		write_reload_manifest "$reload_old_manifest" "$reload_selected_manifest" true
		rm -f "$reload_old_manifest" "$reload_selected_manifest"
		;;
	*)
		printf '%s\n' "unsupported podman compose reload method: $reload_method" >&2
		exit 1
		;;
	esac
	unlock_lifecycle_exclusive
}

cmd_start() {
	local force_recreate=0
	load_metadata
	assert_adoption_allowed
	ensure_runtime_dirs
	lock_lifecycle_exclusive
	mark_start_in_progress
	clear_removal_policy_marker
	record_staging_runtime_state
	stage_runtime_files
	repair_podman_rootless_dns_state
	run_pre_start_hooks || {
		clear_start_in_progress
		unlock_lifecycle_exclusive
		return 1
	}
	if compose_running_container_pids_missing; then
		force_recreate=1
	fi
	if [ "$force_recreate" -eq 1 ] || [ "$podman_network_dns_repaired" -eq 1 ] || should_force_recreate; then
		force_recreate=1
		compose_up_checked force
	else
		compose_up_checked normal
	fi
	if [ "$force_recreate" -eq 1 ]; then
		record_applied_recreate_state
	else
		record_runtime_state
	fi
	clear_start_in_progress
	unlock_lifecycle_exclusive
	notify_ready_and_monitor "podman compose running"
}

cmd_stop() {
	local stop_policy
	load_metadata
	stop_policy="$(current_stop_policy)"
	lock_lifecycle_exclusive
	mark_stop_in_progress
	run_pre_stop_hooks || {
		clear_stop_in_progress
		unlock_lifecycle_exclusive
		return 1
	}
	if ! apply_compose_stop_policy "$stop_policy"; then
		cleanup_failed_compose_stop "$stop_policy" || true
		clear_stop_in_progress
		unlock_lifecycle_exclusive
		return 1
	fi
	clear_stop_in_progress
	unlock_lifecycle_exclusive
}

cmd_post_stop() {
	local stop_policy
	load_metadata
	if [ ! -e "$working_dir" ] &&
		[ ! -f "$manifest_path" ] &&
		[ ! -f "$state_path" ] &&
		[ ! -f "$(legacy_state_path)" ]; then
		return 0
	fi
	if working_dir_is_uninitialized_helper_shell; then
		return 0
	fi
	stop_policy="$(current_stop_policy)"
	lock_lifecycle_exclusive
	if post_stop_should_cleanup_failed_start; then
		printf '%s\n' "systemd reported ${podman_compose_service_name}.service result=${SERVICE_RESULT}; running failed-start cleanup"
		cleanup_failed_compose_start
	elif post_stop_should_cleanup_failed_stop "$stop_policy"; then
		printf '%s\n' "systemd reported ${podman_compose_service_name}.service result=${SERVICE_RESULT}; running failed-stop cleanup"
		cleanup_failed_compose_stop "$stop_policy" || true
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
		if ! apply_compose_stop_policy "$stop_policy" ||
			! apply_compose_post_stop_policy "$stop_policy"; then
			unlock_lifecycle_exclusive
			clear_removal_policy_marker
			return 1
		fi
		unlock_lifecycle_exclusive
	fi
}

cmd_image_pull() {
	load_metadata
	assert_adoption_allowed
	ensure_runtime_dirs
	lock_lifecycle_exclusive
	compose_pull
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
		printf '%s\n' "usage: $0 {link-files|cleanup-files|post-stop|verify|monitor|reload|start|stop|remove|image-pull|logs}" >&2
		exit 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
