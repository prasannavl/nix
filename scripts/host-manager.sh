#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
	REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
	TARGET_SCRIPT="${REPO_ROOT}/pkgs/tools/host-manager/host-manager.sh"
}

main() {
	init_vars
	exec env HOST_MANAGER_REPO_ROOT="${REPO_ROOT}" "${TARGET_SCRIPT}" "$@"
}

main "$@"
