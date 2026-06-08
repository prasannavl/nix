#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: update.sh

Runs all repo maintenance update scripts:
  nix flake update
  lib/ext/*/update.sh
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
	EXT_DIR="${REPO_ROOT}/lib/ext"
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--help | -h)
			usage
			exit 0
			;;
		*)
			die "Unknown argument: $1"
			;;
		esac
	done
}

run_updates() {
	local script
	local -a update_scripts=()

	echo "Running nix flake update"
	(cd "$REPO_ROOT" && nix flake update)

	while IFS= read -r -d '' script; do
		update_scripts+=("$script")
	done < <(find "$EXT_DIR" -mindepth 2 -maxdepth 2 -type f -name update.sh -executable -print0 | sort -z)

	for script in "${update_scripts[@]}"; do
		echo "Running ${script#"$REPO_ROOT"/}"
		"$script"
	done
}

main() {
	init_vars
	parse_args "$@"
	run_updates
}

main "$@"
