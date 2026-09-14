#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: lib/ext/pi/update.sh [--package NAME] [--version VERSION] [--force] [--report] [--ansi|--color=WHEN]

Updates all Pi packages by default. Repeat --package to select packages.
--version requires exactly one selected package.

Examples:
  lib/ext/pi/update.sh
  lib/ext/pi/update.sh --package pi-web
  lib/ext/pi/update.sh --package pi-subagents --version 0.67.0 --force
  lib/ext/pi/update.sh --report
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
	PI_DIR="${REPO_ROOT}/lib/ext/pi"
	SOURCES_FILE="${PI_DIR}/sources.json"
	REQUESTED_VERSION=""
	FORCE=0
	REPORT=0
	COLOR_MODE="auto"
	CHANGED=0
	RUNTIME_DIR=""
	NPM_CACHE=""
	STAGING_DIR=""
	WORKING_SOURCES=""
	ALL_PACKAGES=(
		pi-models-discovery
		pi-session-manager
		pi-subagents
		pi-tps
		pi-web
	)
	REQUESTED_PACKAGES=()
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--package | -p)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			REQUESTED_PACKAGES+=("$2")
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

contains_package() {
	local candidate="$1"
	local package

	for package in "${ALL_PACKAGES[@]}"; do
		[[ "$package" == "$candidate" ]] && return 0
	done
	return 1
}

validate_options() {
	local package

	case "$COLOR_MODE" in
	auto | always | never) ;;
	*) die "--color must be one of: auto, always, never" ;;
	esac

	if ((${#REQUESTED_PACKAGES[@]} == 0)); then
		REQUESTED_PACKAGES=("${ALL_PACKAGES[@]}")
	fi
	for package in "${REQUESTED_PACKAGES[@]}"; do
		contains_package "$package" || die "Unknown Pi package: $package"
	done
	if [[ -n "$REQUESTED_VERSION" ]] && ((${#REQUESTED_PACKAGES[@]} != 1)); then
		die "--version requires exactly one --package"
	fi
	if ((REPORT && FORCE)); then
		die "--report cannot be combined with --force"
	fi
}

npm_name() {
	case "$1" in
	pi-web) echo "@agegr/pi-web" ;;
	*) echo "$1" ;;
	esac
}

github_repo() {
	case "$1" in
	pi-models-discovery) echo "maplezzk pi-extensions" ;;
	pi-subagents) echo "nicobailon pi-subagents" ;;
	pi-tps) echo "summertime-wu pi-tps" ;;
	pi-web) echo "agegr pi-web" ;;
	*) die "No GitHub repository configured for $1" ;;
	esac
}

current_version() {
	jq -er --arg package "$1" '.[$package].version' "$SOURCES_FILE"
}

resolve_metadata() {
	local package="$1"
	local registry_name selector

	registry_name="$(npm_name "$package")"
	selector="${REQUESTED_VERSION:-latest}"
	npm --cache "$NPM_CACHE" --loglevel=silent view "${registry_name}@${selector}" --json
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

report_package() {
	local package="$1"
	local metadata current latest

	metadata="$(resolve_metadata "$package")"
	current="$(current_version "$package")"
	latest="$(jq -er '.version' <<<"$metadata")"
	if [[ "$current" == "$latest" ]]; then
		echo "- ${package}: ${current} [latest]"
	else
		print_update_line "${package}: ${current} -> ${latest}"
	fi
}

prefetch_unpack_hash() {
	local url="$1"

	nix store prefetch-file --json --hash-type sha256 --unpack "$url" |
		jq -er .hash
}

set_source_record() {
	local package="$1"
	local version="$2"
	local rev="$3"
	local src_hash="$4"
	local release_hash="$5"
	local npm_deps_hash="$6"
	local next_file

	next_file="${STAGING_DIR}/sources.next.json"
	jq --sort-keys \
		--arg package "$package" \
		--arg version "$version" \
		--arg rev "$rev" \
		--arg srcHash "$src_hash" \
		--arg releaseHash "$release_hash" \
		--arg npmDepsHash "$npm_deps_hash" \
		'
      .[$package].version = $version
      | .[$package].srcHash = $srcHash
      | if $rev != "" then .[$package].rev = $rev else . end
      | if $releaseHash != "" then .[$package].releaseHash = $releaseHash else . end
      | if $npmDepsHash != "" then .[$package].npmDepsHash = $npmDepsHash else . end
    ' \
		"$WORKING_SOURCES" >"$next_file"
	mv "$next_file" "$WORKING_SOURCES"
}

set_npm_deps_hash() {
	local package="$1"
	local npm_deps_hash="$2"
	local next_file

	next_file="${STAGING_DIR}/sources.next.json"
	jq --sort-keys \
		--arg package "$package" \
		--arg npmDepsHash "$npm_deps_hash" \
		'.[$package].npmDepsHash = $npmDepsHash' \
		"$WORKING_SOURCES" >"$next_file"
	mv "$next_file" "$WORKING_SOURCES"
}

build_package() {
	local package="$1"

	nix-build "${STAGING_DIR}/${package}" --no-out-link >/dev/null
}

compute_npm_deps_hash() {
	local package="$1"
	local build_output build_status npm_deps_hash

	set_npm_deps_hash "$package" "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	set +e
	build_output="$(nix-build "${STAGING_DIR}/${package}" --no-out-link 2>&1)"
	build_status=$?
	set -e
	if ((build_status == 0)); then
		die "Expected fake npmDepsHash build to fail for ${package}"
	fi
	npm_deps_hash="$(awk '/got:[[:space:]]+sha256-/ {print $2}' <<<"$build_output" | tail -n1)"
	[[ -n "$npm_deps_hash" ]] || {
		printf '%s\n' "$build_output" >&2
		die "Could not determine npmDepsHash for ${package}"
	}
	set_npm_deps_hash "$package" "$npm_deps_hash"
}

update_package() {
	local package="$1"
	local metadata current version rev="" src_hash release_hash="" npm_deps_hash=""
	local owner repo tarball

	metadata="$(resolve_metadata "$package")"
	current="$(current_version "$package")"
	version="$(jq -er '.version' <<<"$metadata")"
	if ((!FORCE)) && [[ "$current" == "$version" ]]; then
		echo "${package} already at ${current}; skipping."
		return
	fi

	case "$package" in
	pi-models-discovery | pi-subagents | pi-tps)
		rev="$(jq -er '.gitHead' <<<"$metadata")"
		read -r owner repo <<<"$(github_repo "$package")"
		src_hash="$(prefetch_unpack_hash "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz")"
		;;
	pi-session-manager)
		tarball="$(jq -er '.dist.tarball' <<<"$metadata")"
		src_hash="$(prefetch_unpack_hash "$tarball")"
		;;
	pi-web)
		tarball="$(jq -er '.dist.tarball' <<<"$metadata")"
		src_hash="$(prefetch_unpack_hash "$tarball")"
		read -r owner repo <<<"$(github_repo "$package")"
		release_hash="$(prefetch_unpack_hash "https://github.com/${owner}/${repo}/archive/refs/tags/v${version}.tar.gz")"
		;;
	esac

	set_source_record "$package" "$version" "$rev" "$src_hash" "$release_hash" "$npm_deps_hash"
	if [[ "$package" == "pi-subagents" || "$package" == "pi-web" ]]; then
		compute_npm_deps_hash "$package"
	fi
	build_package "$package"
	CHANGED=1
	print_update_line "${package}: ${current} -> ${version}"
}

init_staging() {
	STAGING_DIR="${RUNTIME_DIR}/suite"
	mkdir -p "$STAGING_DIR"
	cp -R "${PI_DIR}/." "$STAGING_DIR"
	WORKING_SOURCES="${STAGING_DIR}/sources.json"
}

init_runtime() {
	mkdir -p "${REPO_ROOT}/tmp"
	RUNTIME_DIR="$(mktemp -d "${REPO_ROOT}/tmp/update-pi.XXXXXX")"
	NPM_CACHE="${RUNTIME_DIR}/npm-cache"
}

cleanup() {
	if [[ -n "${RUNTIME_DIR:-}" && -d "$RUNTIME_DIR" ]]; then
		find "$RUNTIME_DIR" -depth -delete
	fi
}

install_sources() {
	local formatted_file

	formatted_file="${STAGING_DIR}/sources.formatted.json"
	jq --sort-keys . "$WORKING_SOURCES" >"$formatted_file"
	mv "$formatted_file" "$WORKING_SOURCES"
	mv "$WORKING_SOURCES" "$SOURCES_FILE"
}

ensure_runtime_shell() {
	local runtime_shell_flag="${UPDATE_PI_IN_NIX_SHELL:-0}"
	local script_path flake_path
	local -a runtime_packages=(
		nixpkgs#bash
		nixpkgs#coreutils
		nixpkgs#gawk
		nixpkgs#jq
		nixpkgs#nix
		nixpkgs#nodejs
	)

	if [[ "$runtime_shell_flag" == "1" ]]; then
		return
	fi
	command -v nix >/dev/null 2>&1 || die "Required command not found: nix"

	script_path="${BASH_SOURCE[0]:-$0}"
	flake_path="$(cd "$(dirname "$script_path")/../../.." && pwd -P)"
	exec nix --quiet --no-warn-dirty shell --inputs-from "$flake_path" \
		"${runtime_packages[@]}" -c env UPDATE_PI_IN_NIX_SHELL=1 bash "$script_path" "$@"
}

main() {
	local package

	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	validate_options
	init_runtime
	trap cleanup EXIT

	if ((REPORT)); then
		for package in "${REQUESTED_PACKAGES[@]}"; do
			report_package "$package"
		done
		return
	fi

	init_staging
	for package in "${REQUESTED_PACKAGES[@]}"; do
		update_package "$package"
	done
	if ((CHANGED)); then
		install_sources
	else
		echo "No Pi package updates."
	fi
}

main "$@"
