#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	podman_compose_metadata="${NIX_PODMAN_COMPOSE_METADATA-}"
	podman_compose_service_name="${NIX_PODMAN_COMPOSE_SERVICE_NAME-}"

	runtime_dir="${XDG_RUNTIME_DIR-}"
	manifest_path=""
	working_dir=""
	recreate_on_switch="false"
	monitor_interval=10

	compose_args=()
	compose_file_args=()
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
	recreate_on_switch="$(jq -r '.recreateOnSwitch // false' "$podman_compose_metadata")"

	compose_args=()
	while IFS= read -r compose_arg; do
		[ -n "$compose_arg" ] || continue
		compose_args+=("$compose_arg")
	done < <(jq -r '.composeArgs[]?' "$podman_compose_metadata")

	compose_file_args=()
	while IFS= read -r compose_file; do
		compose_file_args+=(-f "$compose_file")
	done < <(jq -r '.composeFiles[]?' "$podman_compose_metadata")
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
	install -d -m 0700 "$runtime_dir/podman-compose"
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
		install -d -m 0700 "$dst"
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

stage_secret_env_file() {
	local secret_json tmp_manifest dst dst_dir mode user group scope tmp_secret_env entry_json env_name src
	secret_json="$1"
	tmp_manifest="$2"
	dst="$(jq -r '.dst' <<<"$secret_json")"
	dst_dir="$(jq -r '.dstDir' <<<"$secret_json")"
	mode="$(jq -r 'if has("mode") then (.mode // "null") else "0400" end' <<<"$secret_json")"
	user="$(jq -r '.user // "null"' <<<"$secret_json")"
	group="$(jq -r '.group // "null"' <<<"$secret_json")"
	scope="$(jq -r '.scope // "host"' <<<"$secret_json")"
	tmp_secret_env="${dst}.tmp"

	install -d -m 0700 "$dst_dir"
	remove_path_if_exists "$dst"
	remove_path_if_exists "$tmp_secret_env"
	: >"$tmp_secret_env"

	while IFS= read -r entry_json; do
		[ -n "$entry_json" ] || continue
		env_name="$(jq -r '.name' <<<"$entry_json")"
		src="$(jq -r '.src' <<<"$entry_json")"
		{
			printf '%s=' "$env_name"
			tr -d '\n' <"$src"
			printf '\n'
		} >>"$tmp_secret_env"
	done < <(jq -c '.entries[]?' <<<"$secret_json")

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
		podman compose "${compose_args[@]}" "${compose_file_args[@]}" pull 2>&1
	)
}

verify_compose_state() {
	local state_json failing_states
	state_json="$(compose_state_json)"
	failing_states="$(printf '%s' "$state_json" | failing_states_report)"

	if [ -n "$failing_states" ]; then
		printf '%s\n' "podman compose left containers in a non-running state:" >&2
		printf '%s\n' "$failing_states" >&2
		exit 1
	fi
}

monitor_compose_state() {
	local state_json failing_states state_counts total_count running_count
	while true; do
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
			exit 0
		fi

		sleep "$monitor_interval"
	done
}

cmd_link_files() {
	load_metadata
	ensure_runtime_dirs
	stage_runtime_files
}

cmd_cleanup_files() {
	load_metadata
	cleanup_runtime_files
}

cmd_verify() {
	load_metadata
	verify_compose_state
}

cmd_monitor() {
	load_metadata
	monitor_compose_state
}

cmd_reload() {
	load_metadata
	compose_down
	cleanup_runtime_files
	ensure_runtime_dirs
	stage_runtime_files
	compose_up
	verify_compose_state
}

cmd_start() {
	load_metadata
	ensure_runtime_dirs
	stage_runtime_files
	if [ "$recreate_on_switch" = "true" ]; then
		compose_up_force_recreate
	else
		compose_up
	fi
	verify_compose_state
	exec systemd-notify \
		--ready \
		--status="podman compose running" \
		--exec ';' -- \
		"$0" monitor
}

cmd_stop() {
	load_metadata
	if [ -d "$working_dir" ]; then
		compose_down
	else
		(
			cd /
			podman compose "${compose_file_args[@]}" down
		)
	fi
}

cmd_image_pull() {
	load_metadata
	ensure_runtime_dirs
	stage_runtime_files
	compose_pull
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
