#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/sops-secrets.sh encrypt [dir]
  scripts/sops-secrets.sh decrypt [dir]
  scripts/sops-secrets.sh [dir]

Description:
  Encrypts or decrypts matching regular files in place with sops.
  Files are filtered by `path_regex` rules from .sops.yaml.
  When called without an action flag, it auto-toggles each file:
  decrypts encrypted files and encrypts plain files.

Arguments:
  encrypt|decrypt  Operation to perform.
  dir              Target directory (default: data/secrets)
USAGE
}

main() {
  if ! command -v sops >/dev/null 2>&1; then
    echo "Error: 'sops' is required but not found in PATH." >&2
    exit 1
  fi

  local action=""
  local dir="data/secrets"
  local config_file=".sops.yaml"
  local repo_root
  local -a path_regexes=()

  case "${1:-}" in
    encrypt|decrypt)
      action="${1}"
      dir="${2:-data/secrets}"
      ;;
    "")
      action="auto"
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      if [ -d "${1}" ]; then
        action="auto"
        dir="${1}"
      else
        echo "Error: first argument must be 'encrypt', 'decrypt', or a directory path." >&2
        usage
        exit 1
      fi
      ;;
  esac

  if [ ! -d "${dir}" ]; then
    echo "Error: directory not found: ${dir}" >&2
    exit 1
  fi

  repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [ -f "${repo_root}/.sops.yaml" ]; then
    config_file="${repo_root}/.sops.yaml"
  fi
  if [ ! -f "${config_file}" ]; then
    echo "Error: SOPS config not found: ${config_file}" >&2
    exit 1
  fi

  mapfile -t path_regexes < <(
    awk '
      /^[[:space:]]*(-[[:space:]]*)?path_regex:[[:space:]]*/ {
        line = $0
        sub(/^[[:space:]]*(-[[:space:]]*)?path_regex:[[:space:]]*/, "", line)
        sub(/[[:space:]]*#.*$/, "", line)
        gsub(/^["'"'"']|["'"'"']$/, "", line)
        if (length(line) > 0) print line
      }
    ' "${config_file}"
  )
  if [ "${#path_regexes[@]}" -eq 0 ]; then
    echo "Error: no path_regex entries found in ${config_file}" >&2
    exit 1
  fi

  mapfile -t files < <(find "${dir}" -type f | sort)

  if [ "${#files[@]}" -eq 0 ]; then
    echo "No files found in ${dir}."
    exit 0
  fi

  local file
  for file in "${files[@]}"; do
    local relative_file="${file#./}"
    if [[ "${relative_file}" == "${repo_root}/"* ]]; then
      relative_file="${relative_file#${repo_root}/}"
    fi

    local matches_rule="false"
    local path_regex
    for path_regex in "${path_regexes[@]}"; do
      if [[ "${relative_file}" =~ ${path_regex} ]]; then
        matches_rule="true"
        break
      fi
    done
    if [ "${matches_rule}" != "true" ]; then
      echo "skip (no path_regex match): ${file}"
      continue
    fi

    local file_action="${action}"
    local sops_flag

    if [ "${file_action}" = "auto" ]; then
      if sops --decrypt "${file}" >/dev/null 2>&1; then
        file_action="decrypt"
      else
        file_action="encrypt"
      fi
    fi

    if [ "${file_action}" = "encrypt" ]; then
      sops_flag="--encrypt"
    else
      sops_flag="--decrypt"
    fi

    echo "${file_action}: ${file}"
    sops "${sops_flag}" --in-place "${file}"
  done
}

main "$@"
