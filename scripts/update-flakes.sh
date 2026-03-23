#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
}

find_flakes() {
  local -a dirs=()
  local f
  while IFS= read -r -d '' f; do
    dirs+=("$(dirname "$f")")
  done < <(
    find "$REPO_ROOT" \
      -path '*/worktree' -prune -o \
      -name flake.nix -print0
  )
  printf '%s\n' "${dirs[@]}"
}

update_flakes() {
  local dir

  echo "==> Updating root flake: $REPO_ROOT"
  nix flake update --flake "$REPO_ROOT"

  while IFS= read -r dir; do
    [[ "$dir" == "$REPO_ROOT" ]] && continue
    echo "==> Updating child flake: ${dir#"$REPO_ROOT"/}"
    nix flake update --flake "$dir"
  done < <(find_flakes)
}

main() {
  init_vars
  update_flakes
  echo "Done."
}

main "$@"
