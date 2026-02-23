#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
git -C "${repo_root}" config core.hooksPath .githooks

echo "Configured git hooks path: .githooks"
