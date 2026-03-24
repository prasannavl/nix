#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "worker-dir-nix-resolver: failed @ line: %s\n" "${LINENO}" >&2' ERR

runtime_shell_flag() {
  printf '%s\n' "${CLOUDFLARE_WORKER_ASSETS_DIRECTORY_IN_NIX_SHELL:-0}"
}

require_cmd() {
  local cmd="$1"

  if ! command -v "${cmd}" >/dev/null 2>&1; then
    printf '%s is required\n' "${cmd}" >&2
    exit 1
  fi
}

script_path() {
  printf '%s\n' "${BASH_SOURCE[0]:-$0}"
}

repo_root() {
  local script_dir=""

  script_dir="$(cd "$(dirname "$(script_path)")" && pwd -P)"
  cd "${script_dir}/../../../.." && pwd -P
}

ensure_runtime_shell() {
  local root=""
  local script=""
  local -a runtime_packages=(
    nixpkgs#bash
    nixpkgs#coreutils
    nixpkgs#jq
    nixpkgs#nix
  )

  if [ "$(runtime_shell_flag)" = "1" ]; then
    return 0
  fi

  if ! command -v nix >/dev/null 2>&1; then
    printf 'worker-dir-nix-resolver: required command not found: nix\n' >&2
    exit 1
  fi

  root="$(repo_root)" || {
    printf 'worker-dir-nix-resolver: failed to resolve repo root\n' >&2
    exit 1
  }
  script="$(script_path)"

  exec nix shell --inputs-from "${root}" "${runtime_packages[@]}" -c \
    env CLOUDFLARE_WORKER_ASSETS_DIRECTORY_IN_NIX_SHELL=1 \
    bash "${script}" "$@"
}

read_directory_from_stdin() {
  jq -r '.directory // empty'
}

print_error_and_exit() {
  local message="$1"

  printf '%s\n' "${message}" >&2
  exit 1
}

resolve_build_root() {
  local directory="$1"

  if [ -f "${directory}/flake.nix" ]; then
    printf '%s\n' "${directory}"
    return 0
  fi

  if [ "$(basename "${directory}")" = "result" ] && [ -f "$(dirname "${directory}")/flake.nix" ]; then
    printf '%s\n' "$(dirname "${directory}")"
    return 0
  fi

  return 1
}

resolve_directory() {
  local directory="$1"
  local build_root=""

  if build_root="$(resolve_build_root "${directory}")"; then
    local build_output=""
    if ! build_output="$(nix build --no-link --print-out-paths "path:${build_root}#build")"; then
      printf 'worker-dir-nix-resolver: nix build failed for %s\n' "${build_root}" >&2
      exit 1
    fi
    printf '%s\n' "${build_output}" | tail -n1
    return 0
  fi

  printf '%s\n' "${directory}"
}

print_resolved_directory() {
  local directory="$1"
  local resolved_directory=""

  resolved_directory="$(resolve_directory "${directory}")"
  jq -cn --arg directory "${resolved_directory}" '{directory: $directory}'
}

main() {
  local directory=""

  ensure_runtime_shell "$@"
  require_cmd jq
  require_cmd nix

  directory="$(read_directory_from_stdin)"
  [ -n "${directory}" ] || print_error_and_exit "missing directory"
  [ -e "${directory}" ] || print_error_and_exit "directory does not exist: ${directory}"

  print_resolved_directory "${directory}"
}

main "$@"
