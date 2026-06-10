#!/usr/bin/env bash
set -Eeuo pipefail

main() {
	local repo_root script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
	repo_root="$(cd "${script_dir}/../.." && pwd -P)"
	INSTALLER_BUILDER_COMMAND="scripts/support/build-installer-image.sh" exec "${repo_root}/lib/installer/builder.sh" "$@"
}

main "$@"
