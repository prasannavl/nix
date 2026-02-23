#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/sops-check-secrets.sh [--staged-only]

Description:
  Validates secret key files under data/secrets/*.key.
  - Default: checks staged files and modified/untracked working-tree files.
  - --staged-only: checks only staged files (recommended for pre-commit hooks).
USAGE
}

if ! command -v sops >/dev/null 2>&1; then
  echo "pre-commit check failed: 'sops' is required." >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "pre-commit check failed: 'jq' is required." >&2
  exit 1
fi

mode="auto"
case "${1:-}" in
  "")
    ;;
  --staged-only)
    mode="staged"
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown argument: ${1}" >&2
    usage >&2
    exit 1
    ;;
esac

mapfile -t staged_files < <(git diff --cached --name-only --diff-filter=ACMR -- 'data/secrets/*.key')

if [ "${mode}" = "staged" ] && [ "${#staged_files[@]}" -eq 0 ]; then
  exit 0
fi

mapfile -t changed_files < <(git diff --name-only --diff-filter=ACMR -- 'data/secrets/*.key')
mapfile -t untracked_files < <(git ls-files --others --exclude-standard -- 'data/secrets/*.key')

if [ "${#staged_files[@]}" -eq 0 ] && [ "${#changed_files[@]}" -eq 0 ] && [ "${#untracked_files[@]}" -eq 0 ]; then
  exit 0
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp_dir}"
}
trap cleanup EXIT

failed=0

for f in "${staged_files[@]}"; do
  blob_file="${tmp_dir}/$(basename "${f}")"
  git show ":${f}" > "${blob_file}"

  if grep -Eq 'BEGIN OPENSSH PRIVATE KEY|AGE-SECRET-KEY-' "${blob_file}"; then
    echo "Refusing commit: ${f} looks like plaintext secret material (staged)." >&2
    failed=1
    continue
  fi

  if ! jq -e '.sops and .data' "${blob_file}" >/dev/null 2>&1; then
    echo "Refusing commit: ${f} is not a SOPS-encrypted file (staged)." >&2
    failed=1
    continue
  fi

  if ! sops --decrypt --output /dev/null "${blob_file}" >/dev/null 2>&1; then
    echo "Refusing commit: ${f} cannot be decrypted as valid SOPS content (staged)." >&2
    failed=1
  fi
done

if [ "${mode}" != "staged" ]; then
  working_tree_files=()
  if [ "${#changed_files[@]}" -gt 0 ]; then
    working_tree_files+=("${changed_files[@]}")
  fi
  if [ "${#untracked_files[@]}" -gt 0 ]; then
    working_tree_files+=("${untracked_files[@]}")
  fi

  if [ "${#working_tree_files[@]}" -gt 1 ]; then
    mapfile -t working_tree_files < <(printf '%s\n' "${working_tree_files[@]}" | awk '!seen[$0]++')
  fi

  for f in "${working_tree_files[@]}"; do
    blob_file="${tmp_dir}/$(basename "${f}").wt"

    if [ ! -f "${f}" ]; then
      echo "Refusing commit: ${f} no longer exists in working tree." >&2
      failed=1
      continue
    fi
    cat "${f}" > "${blob_file}"

    if grep -Eq 'BEGIN OPENSSH PRIVATE KEY|AGE-SECRET-KEY-' "${blob_file}"; then
      echo "Refusing commit: ${f} looks like plaintext secret material (working-tree)." >&2
      failed=1
      continue
    fi

    if ! jq -e '.sops and .data' "${blob_file}" >/dev/null 2>&1; then
      echo "Refusing commit: ${f} is not a SOPS-encrypted file (working-tree)." >&2
      failed=1
      continue
    fi

    if ! sops --decrypt --output /dev/null "${blob_file}" >/dev/null 2>&1; then
      echo "Refusing commit: ${f} cannot be decrypted as valid SOPS content (working-tree)." >&2
      failed=1
    fi
  done
fi

if [ "${failed}" -ne 0 ]; then
  exit 1
fi
