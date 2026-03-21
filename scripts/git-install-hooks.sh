#!/usr/bin/env bash
set -Eeuo pipefail

# Exception: this helper intentionally skips ensure_runtime_shell because it is
# only used from an already-working Git environment where `git` is present.
init_vars() {
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
}

main() {
  init_vars
  git -C "${REPO_ROOT}" config core.hooksPath .githooks
  echo "Configured git hooks path: .githooks"
}

main "$@"
