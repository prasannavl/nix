#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
	REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
	TARGET_SCRIPT="${REPO_ROOT}/pkgs/tools/nixbot/nixbot.sh"
}

main() {
	init_vars
	exec "${TARGET_SCRIPT}" "$@"
}

main "$@"
