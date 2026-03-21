#!/usr/bin/env bash
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
repo_root="$(cd "${script_dir}/.." && pwd -P)"

exec "${repo_root}/pkgs/nixbot/nixbot.sh" "$@"
