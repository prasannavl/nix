#!/usr/bin/env bash
set -euo pipefail

test "${LINT_IN_NIX_SHELL:-}" = "1"
test -f "${PKG_OPS_MANIFEST:?}"
grep -F '"path":"base"' "$PKG_OPS_MANIFEST" >/dev/null
echo external-repo-lint
