#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
  podman_compose_metadata="${NIX_PODMAN_COMPOSE_METADATA-}"
  podman_compose_service_name="${NIX_PODMAN_COMPOSE_SERVICE_NAME-}"

	runtime_dir="${XDG_RUNTIME_DIR-}"
	manifest_path=""
	working_dir=""

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

stage_runtime_file() {
	local src dst dst_dir tmp_file tmp_manifest
	src="$1"
	dst="$2"
	dst_dir="$3"
	tmp_manifest="$4"
	tmp_file="${dst}.tmp"

	install -d -m 0750 "$dst_dir"
	remove_path_if_exists "$dst"
	remove_path_if_exists "$tmp_file"
	# Write to a temp path first so bind-mounted consumers never see a partially
	# copied file.
	cp -f -- "$src" "$tmp_file"
	mv -f "$tmp_file" "$dst"
	printf '%s\n' "$dst" >>"$tmp_manifest"
}

stage_runtime_files() {
	local tmp_manifest line src dst dst_dir
	tmp_manifest="${manifest_path}.tmp"

	remove_path_if_exists "$tmp_manifest"
	: >"$tmp_manifest"

	while IFS=$'\t' read -r src dst dst_dir; do
		[ -n "$src" ] || continue
		stage_runtime_file "$src" "$dst" "$dst_dir" "$tmp_manifest"
	done < <(jq -r '.stagedFiles[]? | [.src, .dst, .dstDir] | @tsv' "$podman_compose_metadata")

	while IFS= read -r line; do
		[ -n "$line" ] || continue
		stage_secret_env_file "$line" "$tmp_manifest"
	done < <(jq -c '.envSecretFiles[]?' "$podman_compose_metadata")

	mv -f "$tmp_manifest" "$manifest_path"
}

stage_secret_env_file() {
	local secret_json tmp_manifest dst dst_dir tmp_secret_env entry_json env_name src
	secret_json="$1"
	tmp_manifest="$2"
	dst="$(jq -r '.dst' <<<"$secret_json")"
	dst_dir="$(jq -r '.dstDir' <<<"$secret_json")"
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

	chmod 0400 "$tmp_secret_env"
	mv -f "$tmp_secret_env" "$dst"
	printf '%s\n' "$dst" >>"$tmp_manifest"
}

cleanup_runtime_files() {
	local path
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
		podman compose "${compose_file_args[@]}" ps --format json
	)
}

compose_up() {
	(
		cd "$working_dir"
		podman compose "${compose_file_args[@]}" up -d --remove-orphans
	)
}

compose_down() {
	(
		cd "$working_dir"
		podman compose "${compose_file_args[@]}" down
	)
}

compose_pull() {
	(
		cd "$working_dir"
		podman compose "${compose_file_args[@]}" pull
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

		sleep 5
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
	compose_up
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
