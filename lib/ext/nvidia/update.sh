#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: lib/ext/nvidia/update.sh [--version VERSION] [--file PATH] [--force] [--report] [--ansi|--color=WHEN]
Examples:
  lib/ext/nvidia/update.sh
  lib/ext/nvidia/update.sh --version 580.126.09
  lib/ext/nvidia/update.sh --force
  lib/ext/nvidia/update.sh --file lib/ext/nvidia/default.nix
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
	BASE_INDEX_URL="https://download.nvidia.com/XFree86/Linux-x86_64/"
	TARGET_FILE="${REPO_ROOT}/lib/ext/nvidia/default.nix"
	REQUESTED_VERSION=""
	FORCE=0
	REPORT=0
	COLOR_MODE="auto"
	RUNFILE_URL=""
	OPEN_URL=""
	SETTINGS_URL=""
	PERSISTENCED_URL=""
	OPEN_RELEASE_NOTES_URL=""
	SETTINGS_RELEASE_NOTES_URL=""
	PERSISTENCED_RELEASE_NOTES_URL=""
	SHA256_64BIT=""
	OPEN_SHA256=""
	SETTINGS_SHA256=""
	PERSISTENCED_SHA256=""
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--version | -v)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			REQUESTED_VERSION="$2"
			shift 2
			;;
		--file | -f)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			TARGET_FILE="$2"
			shift 2
			;;
		--force)
			FORCE=1
			shift
			;;
		--report)
			REPORT=1
			shift
			;;
		--ansi)
			COLOR_MODE="always"
			shift
			;;
		--color)
			COLOR_MODE="always"
			shift
			;;
		--color=*)
			COLOR_MODE="${1#--color=}"
			shift
			;;
		--help | -h)
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

use_color() {
	case "$COLOR_MODE" in
	always) return 0 ;;
	never) return 1 ;;
	auto) [[ -t 1 ]] ;;
	*) die "--color must be one of: auto, always, never" ;;
	esac
}

print_update_line() {
	local line="$1"
	local current_version="$2"
	local latest_version="$3"
	local color_code="1;38;2;232;170;117"
	if is_attention_update "$current_version" "$latest_version"; then
		color_code="1;38;2;255;150;150"
	fi
	if use_color; then
		printf -- '- \033[%sm%s\033[0m\n' "$color_code" "$line"
	else
		printf -- '- %s\n' "$line"
	fi
}

is_attention_update() {
	local current_version="$1"
	local latest_version="$2"
	local current_major current_minor latest_major latest_minor
	local current_parts latest_parts

	[[ "$current_version" =~ ^v?([0-9]+)([._-]([0-9]+))? ]] || return 1
	current_major="${BASH_REMATCH[1]}"
	current_minor="${BASH_REMATCH[3]:-0}"
	[[ "$latest_version" =~ ^v?([0-9]+)([._-]([0-9]+))? ]] || return 1
	latest_major="${BASH_REMATCH[1]}"
	latest_minor="${BASH_REMATCH[3]:-0}"

	if ((latest_major > current_major)); then
		return 0
	fi
	current_parts="$(grep -oE '[0-9]+' <<<"$current_version" | wc -l)"
	latest_parts="$(grep -oE '[0-9]+' <<<"$latest_version" | wc -l)"
	if [[ "$current_version" =~ ^v?[0-9]+([._-][0-9]+)*$ ]] &&
		[[ "$latest_version" =~ ^v?[0-9]+([._-][0-9]+)*$ ]] &&
		((current_major == 0 && latest_major == 0 && current_parts > 2 && latest_parts > 2 && latest_minor > current_minor)); then
		return 0
	fi
	return 1
}

get_current_version() {
	[[ -f "$TARGET_FILE" ]] || die "Target file not found: $TARGET_FILE"
	sed -nE 's/^[[:space:]]*version = "([^"]+)";.*/\1/p' "$TARGET_FILE" | head -n1
}

get_version() {
	if [[ -n "$REQUESTED_VERSION" ]]; then
		echo "$REQUESTED_VERSION"
		return
	fi

	curl -fsSL "${BASE_INDEX_URL}latest.txt" | awk '{print $1}'
}

print_report() {
	local current_version="$1"
	local latest_version="$2"

	if [[ "$current_version" == "$latest_version" ]]; then
		echo "- nvidia: ${current_version} [latest]"
	else
		print_update_line "nvidia: ${current_version} -> ${latest_version}" "$current_version" "$latest_version"
	fi
}

print_no_update() {
	local current_version="$1"

	echo "NVIDIA $(basename "$TARGET_FILE") already at ${current_version}; skipping prefetch."
	echo "Use --force to recompute hashes for the pinned version."
}

build_urls() {
	local version="$1"
	RUNFILE_URL="${BASE_INDEX_URL}${version}/NVIDIA-Linux-x86_64-${version}.run"
	OPEN_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/${version}.tar.gz"
	SETTINGS_URL="https://github.com/NVIDIA/nvidia-settings/archive/${version}.tar.gz"
	PERSISTENCED_URL="https://github.com/NVIDIA/nvidia-persistenced/archive/${version}.tar.gz"
}

set_optional_url() {
	local target_var="$1"
	local url="$2"

	if curl -fsI "$url" >/dev/null 2>&1; then
		printf -v "$target_var" '%s' "$url"
	fi
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

resolve_release_notes_urls() {
	local version="$1"

	set_optional_url OPEN_RELEASE_NOTES_URL "https://github.com/NVIDIA/open-gpu-kernel-modules/releases/tag/${version}"
	set_optional_url SETTINGS_RELEASE_NOTES_URL "https://github.com/NVIDIA/nvidia-settings/releases/tag/${version}"
	set_optional_url PERSISTENCED_RELEASE_NOTES_URL "https://github.com/NVIDIA/nvidia-persistenced/releases/tag/${version}"
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
	[[ -n "$OPEN_RELEASE_NOTES_URL" ]] && echo "  openReleaseNotesUrl=$OPEN_RELEASE_NOTES_URL"
	[[ -n "$SETTINGS_RELEASE_NOTES_URL" ]] && echo "  settingsReleaseNotesUrl=$SETTINGS_RELEASE_NOTES_URL"
	[[ -n "$PERSISTENCED_RELEASE_NOTES_URL" ]] && echo "  persistencedReleaseNotesUrl=$PERSISTENCED_RELEASE_NOTES_URL"
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
	flake_path="$(cd "$(dirname "${script_path}")/../../.." && pwd -P)"
	exec nix --quiet --no-warn-dirty shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env UPDATE_NVIDIA_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

main() {
	local current_version selected_version

	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"

	current_version="$(get_current_version)"
	selected_version="$(get_version)"
	if ((REPORT)); then
		print_report "$current_version" "$selected_version"
		return
	fi
	if ((!FORCE)) && [[ "$current_version" == "$selected_version" ]]; then
		print_no_update "$current_version"
		return
	fi

	build_urls "$selected_version"
	validate_inputs "$selected_version"
	resolve_release_notes_urls "$selected_version"
	compute_hashes
	update_file "$selected_version"
	print_summary "$selected_version"
}

main "$@"
