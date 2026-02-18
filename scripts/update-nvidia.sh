#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
base_index_url="https://download.nvidia.com/XFree86/Linux-x86_64/"

usage() {
  cat <<EOF
Usage: update-nvidia.sh [--version VERSION] [--file PATH]

Examples:
  update-nvidia.sh
  update-nvidia.sh --version 580.126.09
  update-nvidia.sh --file lib/hardware/nvidia.nix
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

parse_args() {
  target_file="$repo_root/lib/hardware/nvidia.nix"
  requested_version=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version|-v)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        requested_version="$2"
        shift 2
        ;;
      --file|-f)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        target_file="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        if [[ -f "$1" ]]; then
          target_file="$1"
        else
          requested_version="$1"
        fi
        shift
        ;;
    esac
  done
}

get_version() {
  if [[ -n "$requested_version" ]]; then
    echo "$requested_version"
  else
    curl -fsSL "${base_index_url}latest.txt" | awk '{print $1}'
  fi
}

build_urls() {
  local version="$1"
  runfile_url="${base_index_url}${version}/NVIDIA-Linux-x86_64-${version}.run"
  open_url="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/${version}.tar.gz"
  settings_url="https://github.com/NVIDIA/nvidia-settings/archive/${version}.tar.gz"
  persistenced_url="https://github.com/NVIDIA/nvidia-persistenced/archive/${version}.tar.gz"
}

assert_url_exists() {
  local label="$1"
  local url="$2"
  curl -fsI "$url" >/dev/null || die "$label not found: $url"
}

validate_inputs() {
  local version="$1"
  [[ -f "$target_file" ]] || die "Target file not found: $target_file"
  [[ -n "$version" ]] || die "Could not determine NVIDIA version."

  assert_url_exists "NVIDIA runfile" "$runfile_url"
  assert_url_exists "open-gpu-kernel-modules tag" "$open_url"
  assert_url_exists "nvidia-settings tag" "$settings_url"
  assert_url_exists "nvidia-persistenced tag" "$persistenced_url"
}

prefetch_hash() {
  local url="$1"
  shift
  nix store prefetch-file --json --hash-type sha256 "$@" "$url" | jq -r .hash
}

compute_hashes() {
  sha256_64bit="$(prefetch_hash "$runfile_url")"
  open_sha256="$(prefetch_hash "$open_url" --unpack)"
  settings_sha256="$(prefetch_hash "$settings_url" --unpack)"
  persistenced_sha256="$(prefetch_hash "$persistenced_url" --unpack)"
}

update_file() {
  local version="$1"
  sed -E -i \
    -e "s#(^[[:space:]]*version = \").*(\";)#\\1${version}\\2#" \
    -e "s#(^[[:space:]]*sha256_64bit = \").*(\";)#\\1${sha256_64bit}\\2#" \
    -e "s#(^[[:space:]]*openSha256 = \").*(\";)#\\1${open_sha256}\\2#" \
    -e "s#(^[[:space:]]*settingsSha256 = \").*(\";)#\\1${settings_sha256}\\2#" \
    -e "s|(^[[:space:]]*persistencedSha256 = )[^;]+(;[[:space:]]*(\\#.*)?)|\\1\"${persistenced_sha256}\"\\2|" \
    "$target_file"
}

print_summary() {
  local version="$1"
  echo "Updated $(basename "$target_file")"
  echo "  version=$version"
  echo "  sha256_64bit=$sha256_64bit"
  echo "  openSha256=$open_sha256"
  echo "  settingsSha256=$settings_sha256"
  echo "  persistencedSha256=$persistenced_sha256"
}

main() {
  parse_args "$@"
  selected_version="$(get_version)"
  build_urls "$selected_version"
  validate_inputs "$selected_version"
  compute_hashes
  update_file "$selected_version"
  print_summary "$selected_version"
}

main "$@"
