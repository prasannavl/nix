#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: lib/ext/gnome-ext/update.sh [--package NAME] [--version VERSION] [--force] [--report] [--ansi|--color=WHEN]

Updates every extension in sources.nix by default. --version requires one
selected package.
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
	UNIT_DIR="${REPO_ROOT}/lib/ext/gnome-ext"
	SOURCES_FILE="${UNIT_DIR}/sources.nix"
	REQUESTED_PACKAGE=""
	REQUESTED_VERSION=""
	FORCE=0
	REPORT=0
	COLOR_MODE="auto"
	CHANGED=0
	RUNTIME_DIR=""
	STAGING_DIR=""
	PACKAGES=()
	declare -gA UUIDS VERSIONS HASHES
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--package | -p)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			REQUESTED_PACKAGE="$2"
			shift 2
			;;
		--version | -v)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			REQUESTED_VERSION="$2"
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
		--ansi | --color)
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

load_sources() {
	local sources_json package

	sources_json="$(nix eval --json --file "$SOURCES_FILE")"
	mapfile -t PACKAGES < <(jq -er 'keys[]' <<<"$sources_json")
	for package in "${PACKAGES[@]}"; do
		UUIDS[$package]="$(jq -er --arg package "$package" '.[$package].uuid' <<<"$sources_json")"
		VERSIONS[$package]="$(jq -er --arg package "$package" '.[$package].version' <<<"$sources_json")"
		HASHES[$package]="$(jq -er --arg package "$package" '.[$package].hash' <<<"$sources_json")"
	done
}

validate_options() {
	case "$COLOR_MODE" in
	auto | always | never) ;;
	*) die "--color must be one of: auto, always, never" ;;
	esac
	if [[ -n "$REQUESTED_PACKAGE" ]] && [[ -z "${VERSIONS[$REQUESTED_PACKAGE]:-}" ]]; then
		die "Unknown GNOME extension package: $REQUESTED_PACKAGE"
	fi
	if [[ -n "$REQUESTED_VERSION" && -z "$REQUESTED_PACKAGE" ]]; then
		die "--version requires exactly one --package"
	fi
}

use_color() {
	case "$COLOR_MODE" in
	always) return 0 ;;
	never) return 1 ;;
	auto) [[ -t 1 ]] ;;
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

latest_version() {
	local package="$1"
	local info

	if [[ -n "$REQUESTED_VERSION" ]]; then
		echo "$REQUESTED_VERSION"
		return
	fi
	info="$(curl -fsSL "https://extensions.gnome.org/extension-info/?uuid=${UUIDS[$package]}")"
	jq -er '.shell_version_map | to_entries | map(.value.version) | max' <<<"$info"
}

archive_url() {
	local package="$1"
	local version="$2"
	local extension_data_uuid="${UUIDS[$package]//@/}"

	echo "https://extensions.gnome.org/extension-data/${extension_data_uuid}.v${version}.shell-extension.zip"
}

update_package() {
	local package="$1"
	local current latest url hash

	current="${VERSIONS[$package]}"
	latest="$(latest_version "$package")"
	if ((REPORT)); then
		if [[ "$current" == "$latest" ]]; then
			echo "- ${package}: ${current} [latest]"
		else
			print_update_line "${package}: ${current} -> ${latest}"
		fi
		return
	fi
	if [[ "$current" == "$latest" ]] && ((!FORCE)); then
		echo "${package} already at ${current}; skipping prefetch."
		return
	fi

	url="$(archive_url "$package" "$latest")"
	curl -fsI "$url" >/dev/null || die "Extension archive not found: $url"
	hash="$(nix store prefetch-file --json --hash-type sha256 --unpack "$url" | jq -er .hash)"
	VERSIONS[$package]="$latest"
	HASHES[$package]="$hash"
	CHANGED=1
	print_update_line "${package}: ${current} -> ${latest}"
}

render_sources() {
	local package

	echo "{"
	for package in "${PACKAGES[@]}"; do
		cat <<EOF
  ${package} = {
    kind = "gnome-extension";
    uuid = "${UUIDS[$package]}";
    version = "${VERSIONS[$package]}";
    hash = "${HASHES[$package]}";
  };

EOF
	done
	echo "}"
}

write_staged_sources() {
	local next_file="${STAGING_DIR}/sources.next.nix"

	render_sources >"$next_file"
	alejandra "$next_file" >/dev/null
	chmod 0644 "$next_file"
	mv "$next_file" "${STAGING_DIR}/sources.nix"
}

validate_staged_packages() {
	local package

	for package in "${PACKAGES[@]}"; do
		[[ -n "$REQUESTED_PACKAGE" && "$package" != "$REQUESTED_PACKAGE" ]] && continue
		nix build --impure --no-link --expr "
      let
        flake = builtins.getFlake \"${REPO_ROOT}\";
        pkgs = import flake.inputs.nixpkgs { system = builtins.currentSystem; };
      in
        pkgs.callPackage ${STAGING_DIR}/${package}.nix {}
    " >/dev/null
	done
}

init_staging() {
	mkdir -p "${REPO_ROOT}/tmp"
	RUNTIME_DIR="$(mktemp -d "${REPO_ROOT}/tmp/update-gnome-ext.XXXXXX")"
	STAGING_DIR="${RUNTIME_DIR}/gnome-ext"
	cp -R "$UNIT_DIR" "$STAGING_DIR"
}

cleanup() {
	if [[ -n "${RUNTIME_DIR:-}" && -d "$RUNTIME_DIR" ]]; then
		find "$RUNTIME_DIR" -depth -delete
	fi
}

ensure_runtime_shell() {
	local runtime_shell_flag="${UPDATE_GNOME_EXT_IN_NIX_SHELL:-0}"
	local script_path flake_path
	local -a runtime_packages=(
		nixpkgs#alejandra
		nixpkgs#coreutils
		nixpkgs#curl
		nixpkgs#jq
	)

	if [[ "$runtime_shell_flag" == "1" ]]; then
		return
	fi
	command -v nix >/dev/null 2>&1 || die "Required command not found: nix"
	script_path="${BASH_SOURCE[0]:-$0}"
	flake_path="$(cd "$(dirname "$script_path")/../../.." && pwd -P)"
	exec nix --quiet --no-warn-dirty shell --inputs-from "$flake_path" \
		"${runtime_packages[@]}" -c env UPDATE_GNOME_EXT_IN_NIX_SHELL=1 bash "$script_path" "$@"
}

main() {
	local package

	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	load_sources
	validate_options
	if ((!REPORT)); then
		init_staging
		trap cleanup EXIT
	fi

	for package in "${PACKAGES[@]}"; do
		[[ -n "$REQUESTED_PACKAGE" && "$package" != "$REQUESTED_PACKAGE" ]] && continue
		update_package "$package"
	done
	if ((CHANGED)); then
		write_staged_sources
		validate_staged_packages
		mv "${STAGING_DIR}/sources.nix" "$SOURCES_FILE"
	elif ((!REPORT)); then
		echo "No GNOME extension updates."
	fi
}

main "$@"
