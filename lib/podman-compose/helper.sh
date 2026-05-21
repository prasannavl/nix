#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	podman_compose_metadata="${NIX_PODMAN_COMPOSE_METADATA-}"
	podman_compose_service_name="${NIX_PODMAN_COMPOSE_SERVICE_NAME-}"

	runtime_dir="${XDG_RUNTIME_DIR-}"
	generated_dir=""
	manifest_path=""
	lifecycle_lock_path=""
	state_path=""
	legacy_state_path=""
	working_dir=""
	recreate_on_switch="false"
	recreate_tag="0"
	long_running="true"
	reload_method="restart"
	reload_signal="HUP"
	monitor_interval=10

	compose_args=()
	compose_file_args=()
	pull_compose_file_args=()
	reload_services=()
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

load_metadata() {
	local compose_file
	require_env NIX_PODMAN_COMPOSE_METADATA
	require_env NIX_PODMAN_COMPOSE_SERVICE_NAME
	require_env XDG_RUNTIME_DIR

	manifest_path="$runtime_dir/podman-compose/${podman_compose_service_name}.manifest"
	working_dir="$(jq -r '.workingDir' "$podman_compose_metadata")"
	generated_dir="$working_dir/.podman-compose"
	lifecycle_lock_path="$generated_dir/lifecycle.lock"
	state_path="$generated_dir/helper-state.json"
	legacy_state_path="$working_dir/.podman-compose-helper-state.json"
	recreate_on_switch="$(jq -r '.recreateOnSwitch // false' "$podman_compose_metadata")"
	recreate_tag="$(jq -r '.recreateTag // "0"' "$podman_compose_metadata")"
	long_running="$(jq -r '.longRunning // true' "$podman_compose_metadata")"
	reload_method="$(jq -r '.reload.method // "restart"' "$podman_compose_metadata")"
	reload_signal="$(jq -r '.reload.signal // "HUP"' "$podman_compose_metadata")"

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

# apply_perms <path> <mode|null|none> <user|null> <group|null> <scope>
# Applies mode then chown. For scope=container, chown is wrapped in
# `podman unshare` so numeric uid/gid translate through the rootless user
# namespace (e.g. container 1000 -> host SUB+999).
apply_perms() {
	local path mode user group scope chown_spec
	path="$1"
	mode="$2"
	user="$3"
	group="$4"
	scope="$5"

	if [ -n "$mode" ] && [ "$mode" != "null" ] && [ "$mode" != "none" ]; then
		chmod "$mode" "$path"
	fi

	if { [ -n "$user" ] && [ "$user" != "null" ]; } || { [ -n "$group" ] && [ "$group" != "null" ]; }; then
		chown_spec=""
		if [ -n "$user" ] && [ "$user" != "null" ]; then
			chown_spec="$user"
		fi
		if [ -n "$group" ] && [ "$group" != "null" ]; then
			chown_spec="${chown_spec}:${group}"
		fi
		if [ "$scope" = "container" ]; then
			podman unshare chown "$chown_spec" "$path"
		else
			chown "$chown_spec" "$path"
		fi
	fi
}

prepare_staged_dir_for_write() {
	local path scope
	path="$1"
	scope="$2"

	if [ -e "$path" ] || [ -L "$path" ]; then
		if [ ! -d "$path" ] || [ -L "$path" ]; then
			remove_path_if_exists "$path"
			install -d -m 0700 "$path"
			return
		fi

			if [ "$scope" = "container" ]; then
				# Container-scoped dirs are finalized to non-stack host ids. Reset to
				# userns root first so this helper can restage files on the next run.
				# Contents are intentionally untouched; data dirs survive restarts.
				podman unshare chown 0:0 "$path"
			fi
		chmod u+rwx "$path"
	else
		install -d -m 0700 "$path"
	fi
}

prepare_staged_dirs_for_write() {
	local dst scope
	while IFS=$'\t' read -r dst scope; do
		[ -n "$dst" ] || continue
		prepare_staged_dir_for_write "$dst" "$scope"
	done < <(jq -r '(.stagedDirs // [] | sort_by(.dst | length))[] | [.dst, (.scope // "host")] | @tsv' "$podman_compose_metadata")
}

finalize_staged_dirs() {
	local dst mode user group scope
	while IFS=$'\t' read -r dst mode user group scope; do
		[ -n "$dst" ] || continue
		if [ ! -d "$dst" ] || [ -L "$dst" ]; then
			remove_path_if_exists "$dst"
			install -d -m 0700 "$dst"
		fi
		apply_perms "$dst" "$mode" "$user" "$group" "$scope"
	done < <(jq -r '(.stagedDirs // [] | sort_by(.dst | length) | reverse)[] | [.dst, (if has("mode") then (.mode // "null") else "0750" end), (.user // "null"), (.group // "null"), (.scope // "host")] | @tsv' "$podman_compose_metadata")
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
	local dst scope
	while IFS=$'\t' read -r dst scope; do
		[ -n "$dst" ] || continue
		if path_is_under_reload_dir "$dst"; then
			prepare_staged_dir_for_write "$dst" "$scope"
		fi
	done < <(jq -r '(.stagedDirs // [] | sort_by(.dst | length))[] | [.dst, (.scope // "host")] | @tsv' "$podman_compose_metadata")
}

finalize_reload_dirs() {
	local dst mode user group scope
	while IFS=$'\t' read -r dst mode user group scope; do
		[ -n "$dst" ] || continue
		if path_is_under_reload_dir "$dst"; then
			if [ ! -d "$dst" ] || [ -L "$dst" ]; then
				remove_path_if_exists "$dst"
				install -d -m 0700 "$dst"
			fi
			apply_perms "$dst" "$mode" "$user" "$group" "$scope"
		fi
	done < <(jq -r '(.stagedDirs // [] | sort_by(.dst | length) | reverse)[] | [.dst, (if has("mode") then (.mode // "null") else "0750" end), (.user // "null"), (.group // "null"), (.scope // "host")] | @tsv' "$podman_compose_metadata")
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
	local secret_json tmp_manifest dst dst_dir mode user group scope tmp_secret_env env_name src
	secret_json="$1"
	tmp_manifest="$2"
	IFS=$'\t' read -r dst dst_dir mode user group scope < <(
		jq -r '[.dst, .dstDir, (if has("mode") then (.mode // "null") else "0400" end), (.user // "null"), (.group // "null"), (.scope // "host")] | @tsv' <<<"$secret_json"
	)
	tmp_secret_env="${dst}.tmp"

	install -d -m 0700 "$dst_dir"
	remove_path_if_exists "$dst"
	remove_path_if_exists "$tmp_secret_env"
	: >"$tmp_secret_env"

	while IFS=$'\t' read -r env_name src; do
		[ -n "$env_name" ] || continue
		{
			printf '%s=' "$env_name"
			tr -d '\n' <"$src"
			printf '\n'
		} >>"$tmp_secret_env"
	done < <(jq -r '.entries[]? | [.name, .src] | @tsv' <<<"$secret_json")

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
		cd "$working_dir"
		podman compose "${compose_args[@]}" "${compose_file_args[@]}" ps --format json
	)
}

compose_up() {
	(
		cd "$working_dir"
		podman compose "${compose_args[@]}" "${compose_file_args[@]}" up -d --remove-orphans 2>&1
	)
}

compose_up_force_recreate() {
	(
		cd "$working_dir"
		podman compose "${compose_args[@]}" "${compose_file_args[@]}" up -d --remove-orphans --force-recreate 2>&1
	)
}

compose_down() {
	(
		cd "$working_dir"
		podman compose "${compose_args[@]}" "${compose_file_args[@]}" down 2>&1
	)
}

compose_pull() {
	(
		cd "$working_dir"
		podman compose "${compose_args[@]}" "${pull_compose_file_args[@]}" pull 2>&1
	)
}

compose_reload_signal() {
	(
		cd "$working_dir"
		podman compose "${compose_args[@]}" "${compose_file_args[@]}" kill --signal "$reload_signal" "${reload_services[@]}" 2>&1
	)
}

last_applied_recreate_tag() {
	if [ -f "$state_path" ]; then
		jq -r '.recreateTag // "0"' "$state_path" 2>/dev/null || printf '%s\n' "0"
	elif [ -f "$legacy_state_path" ]; then
		jq -r '.recreateTag // "0"' "$legacy_state_path" 2>/dev/null || printf '%s\n' "0"
	else
		printf '%s\n' "0"
	fi
}

should_force_recreate() {
	local applied_recreate_tag
	if [ "$recreate_on_switch" = "true" ]; then
		return 0
	fi
	if [ "$recreate_tag" = "0" ]; then
		return 1
	fi
	applied_recreate_tag="$(last_applied_recreate_tag)"
	[ "$recreate_tag" != "$applied_recreate_tag" ]
}

record_helper_state() {
	local tmp_state
	tmp_state="${state_path}.tmp"
	jq -n --arg recreateTag "$recreate_tag" '{recreateTag: $recreateTag}' >"$tmp_state"
	chmod 0640 "$tmp_state"
	mv -f "$tmp_state" "$state_path"
	rm -f "$legacy_state_path"
}

verify_compose_state() {
	local state_json failing_states state_counts total_count running_count
	state_json="$(compose_state_json)"
	failing_states="$(printf '%s' "$state_json" | failing_states_report)"

	if [ -n "$failing_states" ]; then
		printf '%s\n' "podman compose left containers in a non-running state:" >&2
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
		printf '%s\n' "podman compose found no managed containers" >&2
		exit 1
	fi

	if [ "$running_count" -eq 0 ] && [ "$long_running" = "true" ]; then
		printf '%s\n' "podman compose found no running containers" >&2
		exit 1
	fi
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
	ensure_runtime_dirs
	lock_lifecycle_exclusive
	stage_runtime_files
	unlock_lifecycle_exclusive
}

cmd_verify() {
	load_metadata
	lock_lifecycle_shared
	verify_compose_state
	unlock_lifecycle_shared
}

cmd_monitor() {
	load_metadata
	monitor_compose_state
}

cmd_reload() {
	local working_dir_exists=0 reload_old_manifest reload_selected_manifest
	load_metadata
	[ -d "$working_dir" ] && working_dir_exists=1
	lock_lifecycle_exclusive
	ensure_runtime_dirs
	case "$reload_method" in
	restart)
		if [ "$working_dir_exists" -eq 1 ]; then
			compose_down
		fi
		cleanup_runtime_files
		ensure_runtime_dirs
		stage_runtime_files
		compose_up
		verify_compose_state
		record_helper_state
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
	load_metadata
	ensure_runtime_dirs
	lock_lifecycle_exclusive
	stage_runtime_files
	if should_force_recreate; then
		compose_up_force_recreate
	else
		compose_up
	fi
	verify_compose_state
	record_helper_state
	unlock_lifecycle_exclusive
	exec systemd-notify \
		--ready \
		--status="podman compose running" \
		--exec ';' -- \
		"$0" monitor
}

cmd_stop() {
	local working_dir_exists=0
	load_metadata
	[ -d "$working_dir" ] && working_dir_exists=1
	lock_lifecycle_exclusive
	if [ "$working_dir_exists" -eq 1 ]; then
		compose_down
	else
		printf '%s\n' "podman compose working directory is absent; cannot run compose down safely: $working_dir" >&2
		return 1
	fi
	unlock_lifecycle_exclusive
}

cmd_image_pull() {
	load_metadata
	ensure_runtime_dirs
	lock_lifecycle_exclusive
	compose_pull
	unlock_lifecycle_exclusive
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
	image-pull)
		cmd_image_pull
		;;
	*)
		printf '%s\n' "usage: $0 {link-files|cleanup-files|verify|monitor|reload|start|stop|image-pull}" >&2
		exit 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
