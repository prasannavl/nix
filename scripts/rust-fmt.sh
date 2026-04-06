#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

ensure_runtime_shell() {
  local runtime_shell_flag="${RUST_FMT_IN_NIX_SHELL:-0}"
  local script_path flake_path
  local -a runtime_packages=(
    nixpkgs#bash
    nixpkgs#cargo
    nixpkgs#git
    nixpkgs#rustfmt
  )

  if [ "$runtime_shell_flag" = "1" ]; then
    return
  fi

  if ! command -v nix >/dev/null 2>&1; then
    die "Required command not found: nix"
  fi

  script_path="${BASH_SOURCE[0]:-$0}"
  flake_path="$(cd "$(dirname "${script_path}")/.." && pwd -P)"
  exec nix shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env RUST_FMT_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

main() {
  local repo_root manifest
  local -a manifests=()

  ensure_runtime_shell "$@"
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
  cd "${repo_root}"

  mapfile -t manifests < <(git ls-files 'pkgs/**/Cargo.toml' | sort)

  if [ "${#manifests[@]}" -eq 0 ]; then
    return
  fi

  for manifest in "${manifests[@]}"; do
    cargo fmt --manifest-path "${manifest}" --all
  done
}

main "$@"
