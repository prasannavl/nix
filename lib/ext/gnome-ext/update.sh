#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: lib/ext/gnome-ext/update.sh [--file PATH] [--version VERSION] [--report] [--ansi|--color=WHEN]
By default, updates all known extensions. Optionally specify a single file to update.
Examples:
  lib/ext/gnome-ext/update.sh
  lib/ext/gnome-ext/update.sh --file lib/ext/gnome-ext/p7-borders.nix
  lib/ext/gnome-ext/update.sh --file lib/ext/gnome-ext/p7-cmds.nix --version 30
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
	DEFAULT_FILES=(
		"${REPO_ROOT}/lib/ext/gnome-ext/p7-borders.nix"
		"${REPO_ROOT}/lib/ext/gnome-ext/p7-cmds.nix"
	)
	TARGET_FILE=""
	REQUESTED_VERSION=""
	REPORT=0
	COLOR_MODE="auto"
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
		--file | -f)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			TARGET_FILE="$2"
			shift 2
			;;
		--version | -v)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			REQUESTED_VERSION="$2"
			shift 2
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

get_current_version() {
	sed -nE 's/^[[:space:]]*version = "([^"]+)";.*/\1/p' "$RESOLVED_TARGET_FILE" | head -n1
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

use_color() {
	case "$COLOR_MODE" in
	auto) [[ -t 1 ]] ;;
	always) return 0 ;;
	never) return 1 ;;
	*) die "--color must be one of: auto, always, never" ;;
	esac
}

print_update_line() {
	local line="$1"
	if use_color; then
		printf -- '- \033[1;38;2;232;170;117m%s\033[0m\n' "$line"
	else
		printf -- '- %s\n' "$line"
	fi
}

print_report() {
	local current_version="$1"
	local name

	name="$(basename "$RESOLVED_TARGET_FILE" .nix)"
	if [[ "$current_version" == "$SELECTED_VERSION" ]]; then
		echo "- ${name}: ${current_version} [latest]"
	else
		print_update_line "${name}: ${current_version} -> ${SELECTED_VERSION}"
	fi
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

report_extension() {
	local current_version

	resolve_target_file
	extract_uuid
	current_version="$(get_current_version)"
	[[ -n "$current_version" ]] || die "Could not find version in $RESOLVED_TARGET_FILE"
	resolve_version
	print_report "$current_version"
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
	flake_path="$(cd "$(dirname "${script_path}")/../../.." && pwd -P)"
	exec nix --quiet --no-warn-dirty shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env UPDATE_GNOME_EXT_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

main() {
	local file

	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"

	if [[ -n "$TARGET_FILE" ]]; then
		if ((REPORT)); then
			report_extension
			return
		fi
		update_extension
		return
	fi

	for file in "${DEFAULT_FILES[@]}"; do
		TARGET_FILE="$file"
		if ((REPORT)); then
			report_extension
		else
			update_extension
		fi
	done
}

main "$@"
