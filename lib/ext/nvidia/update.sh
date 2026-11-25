#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: lib/ext/nvidia/update.sh [--branch BRANCH] [--version VERSION] [--file PATH] [--force] [--report] [--ansi|--color=WHEN]

Branches (default: the branch recorded in the target file, else production):
  production   Latest Production Branch Version
  new-feature  Latest New Feature Branch Version
  beta         Latest Beta Version

Examples:
  lib/ext/nvidia/update.sh
  lib/ext/nvidia/update.sh --branch new-feature
  lib/ext/nvidia/update.sh --version 580.126.09
  lib/ext/nvidia/update.sh --force
  lib/ext/nvidia/update.sh --file lib/ext/nvidia/sources.nix
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
	BASE_INDEX_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/"
	# Same lookup used by NVIDIA's PB/NFB/BETA archive.
	DRIVER_LOOKUP_URL="https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=120&lid=1&isWHQL=0&numberOfResults=25&sort1=1&languageCode=1033&osID=12&pfid=985"
	TARGET_FILE="${REPO_ROOT}/lib/ext/nvidia/sources.nix"
	BRANCH=""
	REQUESTED_BRANCH=""
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
		--branch | -b)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			REQUESTED_BRANCH="$2"
			shift 2
			;;
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

get_recorded_branch() {
	[[ -f "$TARGET_FILE" ]] || return 0
	sed -nE 's/^[[:space:]]*branch = "([^"]+)";.*/\1/p' "$TARGET_FILE" | head -n1
}

normalize_branch() {
	case "$1" in
	production | prod) echo "production" ;;
	new-feature | new_feature | nfb) echo "new-feature" ;;
	beta) echo "beta" ;;
	*) die "--branch must be one of: production, new-feature, beta" ;;
	esac
}

resolve_branch() {
	local branch="$REQUESTED_BRANCH"

	[[ -n "$branch" ]] || branch="$(get_recorded_branch)"
	[[ -n "$branch" ]] || branch="production"
	BRANCH="$(normalize_branch "$branch")"
}

parse_lookup_branch_version() {
	local branch="$1"

	# Entries are newest first; flags identify PB/NFB/BETA.
	jq -r --arg branch "$branch" '
		[.IDS[].downloadInfo | select(
			if $branch == "production" then .IsRecommended == "1"
			elif $branch == "new-feature" then .IsRecommended != "1" and .IsFeaturePreview == "1"
			else .IsRecommended != "1" and .IsFeaturePreview != "1" and .IsBeta == "1"
			end
		)] | .[0].DisplayVersion // empty
	'
}

get_version() {
	local version

	if [[ -n "$REQUESTED_VERSION" ]]; then
		echo "$REQUESTED_VERSION"
		return
	fi

	version="$(curl -fsSL "$DRIVER_LOOKUP_URL" | parse_lookup_branch_version "$BRANCH")"
	[[ -n "$version" ]] || die "Could not resolve the latest ${BRANCH} driver version from the NVIDIA driver lookup service"
	echo "$version"
}

print_report() {
	local current_version="$1"
	local latest_version="$2"
	local label="nvidia"

	[[ "$BRANCH" == "production" ]] || label="nvidia/${BRANCH}"
	if [[ "$current_version" == "$latest_version" ]]; then
		echo "- ${label}: ${current_version} [latest]"
	else
		print_update_line "${label}: ${current_version} -> ${latest_version}" "$current_version" "$latest_version"
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

check_artifacts() {
	local current_version="$1" selected_version="$2" url status
	local -a missing=()

	for url in "$RUNFILE_URL" "$OPEN_URL" "$SETTINGS_URL" "$PERSISTENCED_URL"; do
		# GitHub can redirect to a missing archive; check the final response.
		status="$(curl -sSIL --max-time 20 -o /dev/null -w '%{http_code}' "$url")" ||
			die "Could not check NVIDIA ${selected_version} artifact: $url"
		case "$status" in
		2[0-9][0-9]) ;;
		404 | 410) missing+=("HTTP $status: $url") ;;
		*) die "Could not check NVIDIA ${selected_version} artifact (HTTP $status): $url" ;;
		esac
	done

	if ((${#missing[@]})); then
		printf 'NVIDIA %s is missing required artifacts:\n' "$selected_version" >&2
		printf '  %s\n' "${missing[@]}" >&2
		if ((FORCE)) || [[ -n "$REQUESTED_VERSION" || -n "$REQUESTED_BRANCH" ]]; then
			die "Cannot use the explicitly requested NVIDIA release."
		fi
		printf 'Incomplete NVIDIA release; keeping %s.\n' "$current_version" >&2
		return 1
	fi
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
	local tmp_file

	mkdir -p "${REPO_ROOT}/tmp"
	tmp_file="$(mktemp "${REPO_ROOT}/tmp/update-nvidia.XXXXXX.nix")"
	cp "$TARGET_FILE" "$tmp_file"
	sed -E -i \
		-e "s#(^[[:space:]]*version = \").*(\";)#\\1${version}\\2#" \
		-e "s#(^[[:space:]]*sha256_64bit = \").*(\";)#\\1${SHA256_64BIT}\\2#" \
		-e "s#(^[[:space:]]*openSha256 = \").*(\";)#\\1${OPEN_SHA256}\\2#" \
		-e "s#(^[[:space:]]*settingsSha256 = \").*(\";)#\\1${SETTINGS_SHA256}\\2#" \
		-e "s|(^[[:space:]]*persistencedSha256 = )[^;]+(;[[:space:]]*(\\#.*)?)|\\1\"${PERSISTENCED_SHA256}\"\\2|" \
		"$tmp_file"
	if grep -qE '^[[:space:]]*branch = "' "$tmp_file"; then
		sed -E -i "s#(^[[:space:]]*branch = \").*(\";)#\\1${BRANCH}\\2#" "$tmp_file"
	else
		sed -E -i "s#^([[:space:]]*)(version = \")#\\1branch = \"${BRANCH}\";\n\\1\\2#" "$tmp_file"
	fi
	alejandra "$tmp_file" >/dev/null
	chmod 0644 "$tmp_file"
	mv "$tmp_file" "$TARGET_FILE"
}

print_summary() {
	local version="$1"

	echo "Updated $(basename "$TARGET_FILE")"
	echo "  branch=$BRANCH"
	echo "  version=$version"
	echo "  sha256_64bit=$SHA256_64BIT"
	echo "  openSha256=$OPEN_SHA256"
	echo "  settingsSha256=$SETTINGS_SHA256"
	echo "  persistencedSha256=$PERSISTENCED_SHA256"
	[[ -n "$OPEN_RELEASE_NOTES_URL" ]] && echo "  openReleaseNotesUrl=$OPEN_RELEASE_NOTES_URL"
	[[ -n "$SETTINGS_RELEASE_NOTES_URL" ]] && echo "  settingsReleaseNotesUrl=$SETTINGS_RELEASE_NOTES_URL"
	[[ -n "$PERSISTENCED_RELEASE_NOTES_URL" ]] && echo "  persistencedReleaseNotesUrl=$PERSISTENCED_RELEASE_NOTES_URL"
	return 0
}

ensure_runtime_shell() {
	local runtime_shell_flag="${UPDATE_NVIDIA_IN_NIX_SHELL:-0}"
	local script_path
	local flake_path
	local -a runtime_packages=(
		nixpkgs#alejandra
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
	resolve_branch

	current_version="$(get_current_version)"
	selected_version="$(get_version)"
	if ((REPORT)) && [[ -n "$REQUESTED_VERSION" ]]; then
		print_report "$current_version" "$selected_version"
		return
	fi
	if ((!FORCE)) && [[ "$current_version" == "$selected_version" ]]; then
		if ((REPORT)); then
			print_report "$current_version" "$selected_version"
		else
			print_no_update "$current_version"
		fi
		return
	fi

	build_urls "$selected_version"
	check_artifacts "$current_version" "$selected_version" || return 0
	if ((REPORT)); then
		print_report "$current_version" "$selected_version"
		return
	fi

	resolve_release_notes_urls "$selected_version"
	compute_hashes
	update_file "$selected_version"
	print_summary "$selected_version"
}

main "$@"
