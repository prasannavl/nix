#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<'EOF'
Usage:
  scripts/archive/tf-plan-cloudflare-state-migration.sh [options]

Options:
  --zone NAME              Select resources related to a zone/domain. Repeatable.
  --worker NAME            Select resources related to a worker/app. Repeatable.
  --tunnel NAME            Select resources related to a tunnel key. Repeatable.
  --r2-bucket NAME         Select resources related to an R2 bucket key.
                           Repeatable.
  --address-contains TEXT  Select resources whose address or desired metadata
                           mentions the given text. Repeatable.
  --from-run-id ID         Reuse docs/ai/runs/<ID>/manifest.json and desired
                           inventories instead of rebuilding from the repo/API.
  --project NAME           Limit to one project. Repeat for multiple projects.
                           Defaults to: cloudflare-dns, cloudflare-platform,
                           cloudflare-apps.
  --run-id ID              Override the run/session id used under docs/ai/runs/.
  --keep-workspace         Keep the temporary planning workspace under tmp/
                           when rebuilding inventory from the repo/API.
  -h, --help

Behavior:
  - This script is planning-only by default and does not mutate Terraform state.
  - It writes a selective migration plan under docs/ai/runs/<run-id>/:
    - selected-manifest.json
    - import-into-target.sh
    - remove-from-source.sh
  - Run import-into-target.sh first against the target backend credentials.
  - After verification, run remove-from-source.sh against the source backend
    credentials.
EOF
}

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

init_vars() {
	SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
	SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd -P)"
	REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
	HELPER_PATH="${SCRIPT_DIR}/tf-plan-cloudflare-state-migration.py"
}

ensure_runtime_shell() {
	local runtime_shell_flag="${TF_PLAN_MIGRATE_IN_NIX_SHELL:-0}"
	local -a runtime_packages=(
		nixpkgs#age
		nixpkgs#git
		nixpkgs#jq
		nixpkgs#opentofu
		nixpkgs#python3
		nixpkgs#rsync
	)

	if [ "${runtime_shell_flag}" = "1" ]; then
		return
	fi

	command -v nix >/dev/null 2>&1 || die "Required command not found: nix"

	exec nix shell --inputs-from "${REPO_ROOT}" "${runtime_packages[@]}" -c \
		env TF_PLAN_MIGRATE_IN_NIX_SHELL=1 bash "${SCRIPT_PATH}" "$@"
}

main() {
	init_vars
	if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
		usage
		return 0
	fi
	ensure_runtime_shell "$@"
	[ -f "${HELPER_PATH}" ] || die "Helper script not found: ${HELPER_PATH}"
	exec python3 "${HELPER_PATH}" --repo-root "${REPO_ROOT}" "$@"
}

main "$@"
