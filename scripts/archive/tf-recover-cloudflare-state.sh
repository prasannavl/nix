#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/archive/tf-recover-cloudflare-state.sh [options]

Options:
  --apply              Execute imports into the configured Terraform backends.
  --apply-from-run-id ID
                       Reuse docs/ai/runs/<ID>/manifest.json instead of
                       re-reading modules and Cloudflare API. Requires
                       --apply.
  --project NAME       Limit to one project. Repeat for multiple projects.
                       Defaults to: cloudflare-dns, cloudflare-platform,
                       cloudflare-apps.
  --run-id ID          Override the run/session id used under docs/ai/runs/.
  --keep-workspace     Keep the temporary planning workspace under tmp/.
  -h, --help

Behavior:
  - By default this is manifest-only and does not mutate Terraform state.
  - The script only reads repo-managed secrets and Terraform config.
  - It does not modify files under data/secrets/ or tf/ in the repo.
  - It builds an isolated no-backend planning workspace under tmp/ to recover
    the full desired address set even when the live backend state is missing or
    partial.
  - It writes a recovery manifest and shell command list under
    docs/ai/runs/<run-id>/.
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
  HELPER_PATH="${SCRIPT_DIR}/tf-recover-cloudflare-state.py"
}

ensure_runtime_shell() {
  local runtime_shell_flag="${TF_RECOVER_IN_NIX_SHELL:-0}"
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
    env TF_RECOVER_IN_NIX_SHELL=1 bash "${SCRIPT_PATH}" "$@"
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
