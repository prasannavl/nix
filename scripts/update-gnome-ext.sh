#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<EOF
Usage: update-gnome-ext.sh [--file PATH] [--version VERSION]
By default, updates all known extensions. Optionally specify a single file to update.
Examples:
  update-gnome-ext.sh
  update-gnome-ext.sh --file pkgs/ext/p7-borders.nix
  update-gnome-ext.sh --file pkgs/ext/p7-cmds.nix --version 30
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

init_vars() {
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
  DEFAULT_FILES=(
    "${REPO_ROOT}/pkgs/ext/p7-borders.nix"
    "${REPO_ROOT}/pkgs/ext/p7-cmds.nix"
  )
  TARGET_FILE=""
  REQUESTED_VERSION=""
  RESOLVED_TARGET_FILE=""
  UUID=""
  SELECTED_VERSION=""
  EXTENSION_DATA_UUID=""
  ARCHIVE_URL=""
  SHA256=""
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file|-f)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        TARGET_FILE="$2"
        shift 2
        ;;
      --version|-v)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REQUESTED_VERSION="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
      ;;
    esac
  done
}

resolve_target_file() {
  if [[ "$TARGET_FILE" = /* ]]; then
    RESOLVED_TARGET_FILE="$TARGET_FILE"
  else
    RESOLVED_TARGET_FILE="${REPO_ROOT}/$TARGET_FILE"
  fi
  [[ -f "$RESOLVED_TARGET_FILE" ]] || die "Target file not found: $RESOLVED_TARGET_FILE"
}

extract_uuid() {
  UUID="$(sed -nE 's/^[[:space:]]*uuid = "([^"]+)";/\1/p' "$RESOLVED_TARGET_FILE" | head -n1)"
  [[ -n "$UUID" ]] || die "Could not find uuid in $RESOLVED_TARGET_FILE"
}

resolve_version() {
  local info

  if [[ -n "$REQUESTED_VERSION" ]]; then
    SELECTED_VERSION="$REQUESTED_VERSION"
    return
  fi

  info="$(curl -fsSL "https://extensions.gnome.org/extension-info/?uuid=$UUID")"
  SELECTED_VERSION="$(jq -er '.shell_version_map | to_entries | map(.value.version) | max' <<<"$info")"
  [[ -n "$SELECTED_VERSION" ]] || die "Could not determine latest version for $UUID"
}

build_url() {
  EXTENSION_DATA_UUID="${UUID//@/}"
  ARCHIVE_URL="https://extensions.gnome.org/extension-data/${EXTENSION_DATA_UUID}.v${SELECTED_VERSION}.shell-extension.zip"
}

validate_url() {
  curl -fsI "$ARCHIVE_URL" >/dev/null || die "Extension archive not found: $ARCHIVE_URL"
}

compute_hash() {
  SHA256="$(nix store prefetch-file --json --hash-type sha256 --unpack "$ARCHIVE_URL" | jq -r .hash)"
}

update_file() {
  sed -E -i \
    -e "s#(^[[:space:]]*version = \")([0-9]+)(\";)#\\1${SELECTED_VERSION}\\3#" \
    -e "s#(^[[:space:]]*sha256 = \").*(\";)#\\1${SHA256}\\2#" \
    "$RESOLVED_TARGET_FILE"
}

print_summary() {
  echo "Updated $(basename "$RESOLVED_TARGET_FILE")"
  echo "  uuid=$UUID"
  echo "  version=$SELECTED_VERSION"
  echo "  sha256=$SHA256"
}

update_extension() {
  resolve_target_file
  extract_uuid
  resolve_version
  build_url
  validate_url
  compute_hash
  update_file
  print_summary
}

ensure_runtime_shell() {
  local runtime_shell_flag="${UPDATE_GNOME_EXT_IN_NIX_SHELL:-0}"
  local script_path
  local flake_path
  local -a runtime_packages=(
    nixpkgs#coreutils
    nixpkgs#curl
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
  exec nix shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env UPDATE_GNOME_EXT_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

main() {
  local file

  ensure_runtime_shell "$@"
  init_vars
  parse_args "$@"

  if [[ -n "$TARGET_FILE" ]]; then
    update_extension
    return
  fi

  for file in "${DEFAULT_FILES[@]}"; do
    TARGET_FILE="$file"
    update_extension
  done
}

main "$@"
