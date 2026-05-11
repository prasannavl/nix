#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: update.sh

Runs all repo maintenance update scripts:
  nix flake update
  update-vscode.sh
  update-gnome-ext.sh
  update-nvidia.sh
  update-fetchzip-in-derv-hashes.sh
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
	UPDATE_SCRIPTS=(
		"${REPO_ROOT}/scripts/update-vscode.sh"
		"${REPO_ROOT}/scripts/update-gnome-ext.sh"
		"${REPO_ROOT}/scripts/update-nvidia.sh"
		"${REPO_ROOT}/scripts/update-fetchzip-in-derv-hashes.sh"
	)
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

	echo "Running nix flake update"
	(cd "$REPO_ROOT" && nix flake update)

	for script in "${UPDATE_SCRIPTS[@]}"; do
		echo "Running $(basename "$script")"
		"$script"
	done
}

main() {
	init_vars
	parse_args "$@"
	run_updates
}

main "$@"
