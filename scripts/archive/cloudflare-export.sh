#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/archive/cloudflare-export.sh [options]

Options:
  --only all|access|tunnels   Limit export to a single surface.
                              Defaults to exporting all supported
                              Cloudflare resources.
  -h, --help

Behavior:
  - Exports Cloudflare resources (DNS, access, tunnels, workers, R2) into
    repo-managed tfvars under data/secrets/tf/cloudflare/.
  - Calls the Cloudflare API using an age-encrypted API token from the repo.
  - Writes or overwrites age-encrypted tfvars files; does not modify
    Terraform state.
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
  HELPER_PATH="${SCRIPT_DIR}/cloudflare-export.py"
}

ensure_runtime_shell() {
  local runtime_shell_flag="${CF_EXPORT_IN_NIX_SHELL:-0}"
  local -a runtime_packages=(
    nixpkgs#age
    nixpkgs#python3
    nixpkgs#wget
  )

  if [ "${runtime_shell_flag}" = "1" ]; then
    return
  fi

  command -v nix >/dev/null 2>&1 || die "Required command not found: nix"

  exec nix shell --inputs-from "${REPO_ROOT}" "${runtime_packages[@]}" -c \
    env CF_EXPORT_IN_NIX_SHELL=1 bash "${SCRIPT_PATH}" "$@"
}

main() {
  init_vars
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    return 0
  fi
  ensure_runtime_shell "$@"
  [ -f "${HELPER_PATH}" ] || die "Helper script not found: ${HELPER_PATH}"
  exec python3 "${HELPER_PATH}" "$@"
}

main "$@"
