#!/usr/bin/env bash

set -Eeuo pipefail

stage_usage() {
	cat >&2 <<'EOF'
usage: podman-quadlet-helper stage <action> [arguments ...]

actions:
  init <working-dir>
  prepare-dir <path> <mode|-> <owner|-> <group|-> <host|container> <true|false>
  finalize-dir <path> <mode|-> <owner|-> <group|-> <host|container> <true|false>
  stage-file <source> <destination> <mode|-> <owner|-> <group|-> <host|container>
  stage-env <destination> <mode|-> <owner|-> <group|-> <host|container> [name=source ...]
  cleanup <generated-dir> [path ...]
EOF
}

require_argc() {
	local expected="$1"
	shift
	if (($# != expected)); then
		stage_usage
		return 2
	fi
}

validate_scope() {
	case "$1" in
	host | container) ;;
	*)
		printf 'invalid Quadlet staging scope: %s\n' "$1" >&2
		return 2
		;;
	esac
}

validate_once() {
	case "$1" in
	true | false) ;;
	*)
		printf 'invalid Quadlet staging once value: %s\n' "$1" >&2
		return 2
		;;
	esac
}

run_scoped() {
	local scope="$1"
	shift
	validate_scope "$scope"
	if [[ $scope == container ]]; then
		podman unshare "$@"
	else
		"$@"
	fi
}

remove_path() {
	local path="$1"
	if [[ -z $path || $path == / ]]; then
		printf 'refusing unsafe Quadlet staging removal path: %q\n' "$path" >&2
		return 2
	fi
	if [[ -e $path || -L $path ]]; then
		rm -rf -- "$path"
	fi
}

apply_perms() {
	local path="$1" mode="$2" owner="$3" group="$4" scope="$5" ownership
	validate_scope "$scope"
	if [[ $owner != - || $group != - ]]; then
		if [[ $owner == - ]]; then
			ownership=":$group"
		elif [[ $group == - ]]; then
			ownership="$owner"
		else
			ownership="$owner:$group"
		fi
		run_scoped "$scope" chown "$ownership" "$path"
	fi
	if [[ $mode != - ]]; then
		run_scoped "$scope" chmod "$mode" "$path"
	fi
}

init_layout() {
	local working_dir="$1" generated_dir
	generated_dir="$working_dir/.podman-compose"
	install -d -m 0750 "$working_dir" "$generated_dir"
	touch "$generated_dir/lifecycle.lock"
	rm -f -- "$generated_dir/state.json"
}

prepare_dir() {
	local path="$1" mode="$2" owner="$3" group="$4" scope="$5" once="$6"
	validate_scope "$scope"
	validate_once "$once"
	if [[ -e $path || -L $path ]]; then
		if [[ ! -d $path || -L $path ]]; then
			remove_path "$path"
			install -d -m 0700 "$path"
			[[ $once != true ]] || apply_perms "$path" "$mode" "$owner" "$group" "$scope"
			return
		fi
		[[ $once != true ]] || return 0
		if [[ $scope == container ]]; then
			run_scoped "$scope" chown 0:0 "$path"
		fi
		run_scoped "$scope" chmod u+rwx "$path"
	else
		install -d -m 0700 "$path"
		[[ $once != true ]] || apply_perms "$path" "$mode" "$owner" "$group" "$scope"
	fi
	return 0
}

finalize_dir() {
	local path="$1" mode="$2" owner="$3" group="$4" scope="$5" once="$6"
	validate_scope "$scope"
	validate_once "$once"
	[[ $once != true ]] || return 0
	if [[ ! -d $path || -L $path ]]; then
		remove_path "$path"
		install -d -m 0700 "$path"
	fi
	apply_perms "$path" "$mode" "$owner" "$group" "$scope"
}

stage_file() {
	local src="$1" dst="$2" mode="$3" owner="$4" group="$5" scope="$6"
	local dst_dir tmp
	dst_dir="$(dirname "$dst")"
	tmp="$dst.tmp"
	install -d -m 0750 "$dst_dir"
	remove_path "$tmp"
	cp -f --preserve=mode -- "$src" "$tmp"
	apply_perms "$tmp" "$mode" "$owner" "$group" "$scope"
	if [[ -d $dst && ! -L $dst ]]; then
		remove_path "$dst"
	fi
	mv -fT -- "$tmp" "$dst"
}

stage_env() {
	local dst="$1" mode="$2" owner="$3" group="$4" scope="$5"
	local dst_dir env_name mapping src tmp
	shift 5
	dst_dir="$(dirname "$dst")"
	tmp="$dst.tmp"
	install -d -m 0700 "$dst_dir"
	remove_path "$tmp"
	{
		for mapping in "$@"; do
			if [[ $mapping != *=* ]]; then
				printf 'invalid Quadlet environment-secret mapping: %s\n' "$mapping" >&2
				return 2
			fi
			env_name="${mapping%%=*}"
			src="${mapping#*=}"
			printf '%s=' "$env_name"
			tr -d '\n' <"$src"
			printf '\n'
		done
	} >"$tmp"
	apply_perms "$tmp" "$mode" "$owner" "$group" "$scope"
	if [[ -d $dst && ! -L $dst ]]; then
		remove_path "$dst"
	fi
	mv -fT -- "$tmp" "$dst"
}

cleanup() {
	local generated_dir="$1" path
	shift
	for path in "$@"; do
		remove_path "$path.tmp"
		remove_path "$path"
	done
	rm -f -- "$generated_dir/state.json"
}

stage_main() {
	local action="${1:-}"
	[[ -n $action ]] || {
		stage_usage
		return 2
	}
	shift

	case "$action" in
	init)
		require_argc 1 "$@"
		init_layout "$@"
		;;
	prepare-dir)
		require_argc 6 "$@"
		prepare_dir "$@"
		;;
	finalize-dir)
		require_argc 6 "$@"
		finalize_dir "$@"
		;;
	stage-file)
		require_argc 6 "$@"
		stage_file "$@"
		;;
	stage-env)
		if (($# < 5)); then
			stage_usage
			return 2
		fi
		stage_env "$@"
		;;
	cleanup)
		if (($# < 1)); then
			stage_usage
			return 2
		fi
		cleanup "$@"
		;;
	*)
		stage_usage
		return 2
		;;
	esac
}

hook_usage() {
	cat >&2 <<'EOF'
usage: podman-quadlet-helper hook <pre-start|post-start|pre-stop> <working-dir> <path> [command-file ...]
EOF
}

run_hook() {
	local hook_name command hook_path working_dir ignore_failure=0 status=0
	hook_name="$1"
	working_dir="$2"
	hook_path="$3"
	command="$4"

	if [[ ${command#-} != "$command" ]]; then
		ignore_failure=1
		command="${command#-}"
	fi
	[[ -n $command ]] || return 0

	if (
		export PATH="$hook_path"
		if [[ -d $working_dir ]]; then
			cd "$working_dir"
		else
			cd /
		fi
		/bin/sh -eu -c "$command"
	); then
		return 0
	else
		status=$?
	fi

	if ((ignore_failure)); then
		printf 'podman Quadlet %s hook failed with status %s; ignoring\n' "$hook_name" "$status"
		return 0
	fi
	printf 'podman Quadlet %s hook failed with status %s\n' "$hook_name" "$status" >&2
	return "$status"
}

hook_main() {
	local hook_name hook_path working_dir command command_file
	if (($# < 3)); then
		hook_usage
		return 2
	fi
	hook_name="$1"
	working_dir="$2"
	hook_path="$3"
	shift 3

	case "$hook_name" in
	pre-start | post-start | pre-stop) ;;
	*)
		hook_usage
		return 2
		;;
	esac

	for command_file in "$@"; do
		if [[ ! -f $command_file ]]; then
			printf 'missing Quadlet %s hook command file: %s\n' "$hook_name" "$command_file" >&2
			return 2
		fi
		command="$(<"$command_file")"
		run_hook "$hook_name" "$working_dir" "$hook_path" "$command"
	done
}

health_usage() {
	cat >&2 <<'EOF'
usage: podman-quadlet-helper health wait <container> <timeout-seconds>
       podman-quadlet-helper health wait-bundle <manifest> <timeout-seconds>
EOF
}

validate_health_timeout() {
	local timeout_seconds="$1"
	if [[ ! $timeout_seconds =~ ^[1-9][0-9]*$ ]]; then
		printf 'invalid Quadlet health timeout: %s\n' "$timeout_seconds" >&2
		return 2
	fi
}

health_status() {
	local container="$1" status
	if ! status="$({
		podman inspect \
			--format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' \
			"$container" 2>/dev/null
	})"; then
		status="missing"
	fi
	printf '%s\n' "$status"
}

health_wait() {
	local container="$1" timeout_seconds="$2" deadline status="unknown"
	validate_health_timeout "$timeout_seconds"
	deadline=$((SECONDS + timeout_seconds))
	while ((SECONDS < deadline)); do
		status="$(health_status "$container")"
		if [[ $status == healthy ]]; then
			return 0
		fi
		sleep 1
	done
	printf 'Quadlet container %s did not become healthy within %ss; last status: %s\n' \
		"$container" "$timeout_seconds" "$status" >&2
	return 1
}

health_wait_bundle() {
	local manifest="$1" timeout_seconds="$2" deadline container manifest_json status pending
	local -a containers=()
	validate_health_timeout "$timeout_seconds"
	if [[ ! -f $manifest ]]; then
		printf 'missing Quadlet health manifest: %s\n' "$manifest" >&2
		return 2
	fi
	manifest_json="$(
		jq -ce \
			'if type == "array" and all(.[]; type == "string" and length > 0) then . else error("invalid health manifest") end' \
			"$manifest"
	)"
	mapfile -t containers < <(jq -r '.[]' <<<"$manifest_json")
	deadline=$((SECONDS + timeout_seconds))
	while ((SECONDS < deadline)); do
		pending=0
		for container in "${containers[@]}"; do
			status="$(health_status "$container")"
			if [[ $status != healthy ]]; then
				pending=1
			fi
		done
		if ((pending == 0)); then
			return 0
		fi
		sleep 1
	done
	printf 'Quadlet bundle did not become healthy within %ss: %s\n' \
		"$timeout_seconds" "$manifest" >&2
	return 1
}

health_main() {
	local action="${1:-}"
	[[ -n $action ]] || {
		health_usage
		return 2
	}
	shift
	case "$action" in
	wait)
		if (($# != 2)); then
			health_usage
			return 2
		fi
		health_wait "$@"
		;;
	wait-bundle)
		if (($# != 2)); then
			health_usage
			return 2
		fi
		health_wait_bundle "$@"
		;;
	*)
		health_usage
		return 2
		;;
	esac
}

usage() {
	cat >&2 <<'EOF'
usage: podman-quadlet-helper <health|hook|stage> ...
EOF
}

main() {
	local command="${1:-}"
	[[ -n $command ]] || {
		usage
		return 2
	}
	shift

	case "$command" in
	health)
		health_main "$@"
		;;
	hook)
		hook_main "$@"
		;;
	stage)
		stage_main "$@"
		;;
	*)
		usage
		return 2
		;;
	esac
}

main "$@"
