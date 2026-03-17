#!/usr/bin/env bash
set -euo pipefail

RUNTIME_SHELL_FLAG="${UPDATE_GNOME_EXT_IN_NIX_SHELL:-0}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# Default list of extensions to update
default_files=(
  "$repo_root/pkgs/ext/p7-borders.nix"
  "$repo_root/pkgs/ext/p7-cmds.nix"
)

usage() {
  cat <<EOF
Usage: update-gnome-ext.sh [--file PATH] [--version VERSION]

By default, updates all known extensions. Optionally specify a single file to update.

Examples:
  update-gnome-ext.sh                               # Update all extensions
  update-gnome-ext.sh --file pkgs/ext/p7-borders.nix    # Update only p7-borders
  update-gnome-ext.sh --file pkgs/ext/p7-cmds.nix --version 30
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

parse_args() {
  target_file=""
  requested_version=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --file|-f)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        target_file="$2"
        shift 2
        ;;
      --version|-v)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        requested_version="$2"
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
  if [[ "$target_file" = /* ]]; then
    resolved_target_file="$target_file"
  else
    resolved_target_file="$repo_root/$target_file"
  fi

  [[ -f "$resolved_target_file" ]] || die "Target file not found: $resolved_target_file"
}

extract_uuid() {
  uuid="$(sed -nE 's/^[[:space:]]*uuid = "([^"]+)";/\1/p' "$resolved_target_file" | head -n1)"
  [[ -n "$uuid" ]] || die "Could not find uuid in $resolved_target_file"
}

resolve_version() {
  if [[ -n "$requested_version" ]]; then
    selected_version="$requested_version"
    return
  fi

  local info
  info="$(curl -fsSL "https://extensions.gnome.org/extension-info/?uuid=$uuid")"
  selected_version="$(jq -er '.shell_version_map | to_entries | map(.value.version) | max' <<<"$info")"
  [[ -n "$selected_version" ]] || die "Could not determine latest version for $uuid"
}

build_url() {
  extension_data_uuid="${uuid//@/}"
  archive_url="https://extensions.gnome.org/extension-data/${extension_data_uuid}.v${selected_version}.shell-extension.zip"
}

validate_url() {
  curl -fsI "$archive_url" >/dev/null || die "Extension archive not found: $archive_url"
}

compute_hash() {
  sha256="$(nix store prefetch-file --json --hash-type sha256 --unpack "$archive_url" | jq -r .hash)"
}

update_file() {
  sed -E -i \
    -e "s#(^[[:space:]]*version = \")([0-9]+)(\";)#\\1${selected_version}\\3#" \
    -e "s#(^[[:space:]]*sha256 = \").*(\";)#\\1${sha256}\\2#" \
    "$resolved_target_file"
}

print_summary() {
  echo "Updated $(basename "$resolved_target_file")"
  echo "  uuid=$uuid"
  echo "  version=$selected_version"
  echo "  sha256=$sha256"
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
  local script_path
  local flake_path
  local -a runtime_packages=(
    nixpkgs#coreutils
    nixpkgs#curl
    nixpkgs#gnused
    nixpkgs#jq
  )

  if [ "${RUNTIME_SHELL_FLAG}" = "1" ]; then
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
  ensure_runtime_shell "$@"
  parse_args "$@"

  if [[ -n "$target_file" ]]; then
    # Single file mode
    update_extension
  else
    # Default: update all known extensions
    for file in "${default_files[@]}"; do
      target_file="$file"
      update_extension
    done
  fi
}

main "$@"
