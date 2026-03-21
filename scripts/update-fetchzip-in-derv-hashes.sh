#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  echo "$*" >&2
  exit 1
}

init_vars() {
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
  TARGET_GLOB="${REPO_ROOT}/pkgs/ext/*.nix"
}

ensure_runtime_shell() {
  local runtime_shell_flag="${UPDATE_FETCHZIP_HASHES_IN_NIX_SHELL:-0}"
  local script_path
  local flake_path
  local -a runtime_packages=(
    nixpkgs#coreutils
    nixpkgs#gnused
    nixpkgs#jq
  )
  if [ "$runtime_shell_flag" = "1" ]; then
    return
  fi
  if ! command -v nix >/dev/null 2>&1; then
    die "Required command not found: nix"
  fi
  script_path="${BASH_SOURCE[0]:-$0}"
  flake_path="$(cd "$(dirname "${script_path}")/.." && pwd -P)"
  exec nix shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env UPDATE_FETCHZIP_HASHES_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

main() {
  local file
  local abs_file
  local url
  local hash

  ensure_runtime_shell "$@"
  init_vars

  for file in ${TARGET_GLOB}; do
    abs_file="$(realpath "$file")"
    url="$(FILE_PATH="$abs_file" nix eval --raw --impure --expr '
      let
        f = import (builtins.toPath (builtins.getEnv "FILE_PATH"));
        args = builtins.mapAttrs (name: _:
          if name == "stdenv" then { mkDerivation = x: x; }
          else if name == "fetchzip" then (x: x)
          else null
        ) (builtins.functionArgs f);
        pkg = f args;
      in pkg.src.url
    ')"
    hash="$(nix store prefetch-file --json --hash-type sha256 --unpack "$url" | jq -r .hash)"
    sed -E -i "s#(sha256 = \").*(\";)#\1$hash\2#" "$abs_file"
    echo "$(basename "$abs_file"): $hash"
  done
}

main "$@"
