#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<EOF
Usage: update-nvidia.sh [--version VERSION] [--file PATH]
Examples:
  update-nvidia.sh
  update-nvidia.sh --version 580.126.09
  update-nvidia.sh --file pkgs/ext/nvidia-driver.nix
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

init_vars() {
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
  BASE_INDEX_URL="https://download.nvidia.com/XFree86/Linux-x86_64/"
  TARGET_FILE="${REPO_ROOT}/pkgs/ext/nvidia-driver.nix"
  REQUESTED_VERSION=""
  RUNFILE_URL=""
  OPEN_URL=""
  SETTINGS_URL=""
  PERSISTENCED_URL=""
  SHA256_64BIT=""
  OPEN_SHA256=""
  SETTINGS_SHA256=""
  PERSISTENCED_SHA256=""
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version|-v)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        REQUESTED_VERSION="$2"
        shift 2
        ;;
      --file|-f)
        [[ $# -ge 2 ]] || die "Missing value for $1"
        TARGET_FILE="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        if [[ -f "$1" ]]; then
          TARGET_FILE="$1"
        else
          REQUESTED_VERSION="$1"
        fi
        shift
      ;;
    esac
  done
}

get_version() {
  if [[ -n "$REQUESTED_VERSION" ]]; then
    echo "$REQUESTED_VERSION"
    return
  fi

  curl -fsSL "${BASE_INDEX_URL}latest.txt" | awk '{print $1}'
}

build_urls() {
  local version="$1"
  RUNFILE_URL="${BASE_INDEX_URL}${version}/NVIDIA-Linux-x86_64-${version}.run"
  OPEN_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/${version}.tar.gz"
  SETTINGS_URL="https://github.com/NVIDIA/nvidia-settings/archive/${version}.tar.gz"
  PERSISTENCED_URL="https://github.com/NVIDIA/nvidia-persistenced/archive/${version}.tar.gz"
}

assert_url_exists() {
  local label="$1"
  local url="$2"
  curl -fsI "$url" >/dev/null || die "$label not found: $url"
}

validate_inputs() {
  local version="$1"

  [[ -f "$TARGET_FILE" ]] || die "Target file not found: $TARGET_FILE"
  [[ -n "$version" ]] || die "Could not determine NVIDIA version."

  assert_url_exists "NVIDIA runfile" "$RUNFILE_URL"
  assert_url_exists "open-gpu-kernel-modules tag" "$OPEN_URL"
  assert_url_exists "nvidia-settings tag" "$SETTINGS_URL"
  assert_url_exists "nvidia-persistenced tag" "$PERSISTENCED_URL"
}

prefetch_hash() {
  local url="$1"
  shift
  nix store prefetch-file --json --hash-type sha256 "$@" "$url" | jq -r .hash
}

compute_hashes() {
  SHA256_64BIT="$(prefetch_hash "$RUNFILE_URL")"
  OPEN_SHA256="$(prefetch_hash "$OPEN_URL" --unpack)"
  SETTINGS_SHA256="$(prefetch_hash "$SETTINGS_URL" --unpack)"
  PERSISTENCED_SHA256="$(prefetch_hash "$PERSISTENCED_URL" --unpack)"
}

update_file() {
  local version="$1"

  sed -E -i \
    -e "s#(^[[:space:]]*version = \").*(\";)#\\1${version}\\2#" \
    -e "s#(^[[:space:]]*sha256_64bit = \").*(\";)#\\1${SHA256_64BIT}\\2#" \
    -e "s#(^[[:space:]]*openSha256 = \").*(\";)#\\1${OPEN_SHA256}\\2#" \
    -e "s#(^[[:space:]]*settingsSha256 = \").*(\";)#\\1${SETTINGS_SHA256}\\2#" \
    -e "s|(^[[:space:]]*persistencedSha256 = )[^;]+(;[[:space:]]*(\\#.*)?)|\\1\"${PERSISTENCED_SHA256}\"\\2|" \
    "$TARGET_FILE"
}

print_summary() {
  local version="$1"

  echo "Updated $(basename "$TARGET_FILE")"
  echo "  version=$version"
  echo "  sha256_64bit=$SHA256_64BIT"
  echo "  openSha256=$OPEN_SHA256"
  echo "  settingsSha256=$SETTINGS_SHA256"
  echo "  persistencedSha256=$PERSISTENCED_SHA256"
}

ensure_runtime_shell() {
  local runtime_shell_flag="${UPDATE_NVIDIA_IN_NIX_SHELL:-0}"
  local script_path
  local flake_path
  local -a runtime_packages=(
    nixpkgs#curl
    nixpkgs#gawk
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
  exec nix shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env UPDATE_NVIDIA_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

main() {
  local selected_version

  ensure_runtime_shell "$@"
  init_vars
  parse_args "$@"

  selected_version="$(get_version)"
  build_urls "$selected_version"
  validate_inputs "$selected_version"
  compute_hashes
  update_file "$selected_version"
  print_summary "$selected_version"
}

main "$@"
