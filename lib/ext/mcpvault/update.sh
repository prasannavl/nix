#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: lib/ext/mcpvault/update.sh [--version VERSION] [--force] [--report] [--ansi|--color=WHEN]

Regenerates sources.nix and runtime/{package.json,package-lock.json} together:
the runtime lock pins the npm release and its dependency closure. Candidates
are staged and built before any file is replaced.

Examples:
  lib/ext/mcpvault/update.sh
  lib/ext/mcpvault/update.sh --report
  lib/ext/mcpvault/update.sh --version 0.18.4 --force
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
	UNIT_DIR="${REPO_ROOT}/lib/ext/mcpvault"
	SOURCES_FILE="${UNIT_DIR}/sources.nix"
	PACKAGE="@bitbonsai/mcpvault"
	REGISTRY="https://registry.npmjs.org"
	FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	REQUESTED_VERSION=""
	FORCE=0
	REPORT=0
	COLOR_MODE="auto"
	RUNTIME_DIR=""
	STAGING_DIR=""
	RESOLVED_VERSION=""
	NPM_DEPS_HASH=""
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--version | -v)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			REQUESTED_VERSION="${2#v}"
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
	case "$COLOR_MODE" in
	auto | always | never) ;;
	*) die "--color must be one of: auto, always, never" ;;
	esac
	if ((REPORT && FORCE)); then
		die "--report cannot be combined with --force"
	fi
}

use_color() {
	case "$COLOR_MODE" in
	always) return 0 ;;
	never) return 1 ;;
	auto) [[ -t 1 ]] ;;
	esac
}

print_report() {
	local current="$1"
	local line="mcpvault: ${current} -> ${RESOLVED_VERSION}"

	if [[ "$current" == "$RESOLVED_VERSION" ]]; then
		echo "- mcpvault: ${current} [latest]"
	elif use_color; then
		printf -- '- \033[1;38;2;232;170;117m%s\033[0m\n' "$line"
	else
		printf -- '- %s\n' "$line"
	fi
}

current_version() {
	nix eval --raw --file "$SOURCES_FILE" mcpvault.version
}

resolve_version() {
	local selector="${REQUESTED_VERSION:-latest}"
	local encoded="${PACKAGE/\//%2f}"

	RESOLVED_VERSION="$(curl -fsSL "${REGISTRY}/${encoded}/${selector}" | jq -er .version)" ||
		die "Could not resolve ${PACKAGE}@${selector}"
}

init_runtime() {
	mkdir -p "${REPO_ROOT}/tmp"
	RUNTIME_DIR="$(mktemp -d "${REPO_ROOT}/tmp/update-mcpvault.XXXXXX")"
	STAGING_DIR="${RUNTIME_DIR}/unit"
}

cleanup() {
	case "${RUNTIME_DIR:-}" in
	"${REPO_ROOT}"/tmp/update-mcpvault.??????) find "$RUNTIME_DIR" -depth -delete ;;
	esac
}

stage_lock() {
	mkdir -p "${STAGING_DIR}/runtime"
	cp "${UNIT_DIR}/default.nix" "${STAGING_DIR}/default.nix"
	jq -n --arg package "$PACKAGE" --arg version "$RESOLVED_VERSION" '{
		name: "mcpvault-runtime",
		private: true,
		version: "0.0.0",
		dependencies: {($package): $version}
	}' >"${STAGING_DIR}/runtime/package.json"

	# Ignore user npm config so the lock always resolves against the public registry.
	: >"${RUNTIME_DIR}/npmrc"
	(
		cd "${STAGING_DIR}/runtime"
		NPM_CONFIG_USERCONFIG="${RUNTIME_DIR}/npmrc" npm install \
			--package-lock-only --ignore-scripts --no-audit --no-fund --no-update-notifier \
			--registry "${REGISTRY}/" --cache "${RUNTIME_DIR}/npm-cache" >/dev/null
	)
	jq -e --arg key "node_modules/${PACKAGE}" --arg version "$RESOLVED_VERSION" \
		'.packages[$key].version == $version' \
		"${STAGING_DIR}/runtime/package-lock.json" >/dev/null ||
		die "Generated lock does not pin ${PACKAGE}@${RESOLVED_VERSION}"
}

render_sources() {
	local npm_deps_hash="$1"
	local next_file="${STAGING_DIR}/sources.next.nix"

	cat >"$next_file" <<EOF
{
  mcpvault = {
    # npm release. update.sh regenerates runtime/, whose lock pins this release
    # and its dependency closure; npmDepsHash covers that lock.
    kind = "npm";
    package = "${PACKAGE}";
    owner = "bitbonsai";
    repo = "mcpvault";
    version = "${RESOLVED_VERSION}";
    npmDepsHash = "${npm_deps_hash}";
  };
}
EOF
	alejandra --quiet "$next_file" >/dev/null
	chmod 0644 "$next_file"
	mv "$next_file" "${STAGING_DIR}/sources.nix"
}

build_staged() {
	nix build --impure --no-link \
		--argstr repoRoot "$REPO_ROOT" \
		--argstr packageDir "$STAGING_DIR" \
		--expr '
      {repoRoot, packageDir}: let
        flake = import (repoRoot + "/ab/repo/self-flake.nix") {repoRoot = repoRoot;};
        pkgs = builtins.getAttr builtins.currentSystem flake.inputs.nixpkgs.legacyPackages;
      in
        pkgs.callPackage (packageDir + "/default.nix") {}
    '
}

compute_npm_deps_hash() {
	local build_output

	render_sources "$FAKE_HASH"
	if build_output="$(build_staged 2>&1)"; then
		die "Expected fake npmDepsHash build to fail"
	fi
	NPM_DEPS_HASH="$(awk '/got:[[:space:]]+sha256-/ {print $2}' <<<"$build_output" | tail -n1)"
	[[ -n "$NPM_DEPS_HASH" ]] || {
		printf '%s\n' "$build_output" >&2
		die "Could not determine npmDepsHash"
	}
	render_sources "$NPM_DEPS_HASH"
}

install_files() {
	local name

	# The lock first, sources.nix last: the package asserts they agree.
	mkdir -p "${UNIT_DIR}/runtime"
	for name in package.json package-lock.json; do
		chmod 0644 "${STAGING_DIR}/runtime/${name}"
		mv "${STAGING_DIR}/runtime/${name}" "${UNIT_DIR}/runtime/${name}"
	done
	mv "${STAGING_DIR}/sources.nix" "$SOURCES_FILE"
}

ensure_runtime_shell() {
	local runtime_shell_flag="${UPDATE_MCPVAULT_IN_NIX_SHELL:-0}"
	local script_path flake_path
	local -a runtime_packages=(
		nixpkgs#alejandra
		nixpkgs#bash
		nixpkgs#coreutils
		nixpkgs#curl
		nixpkgs#findutils
		nixpkgs#gawk
		nixpkgs#jq
		nixpkgs#nix
		nixpkgs#nodejs_22
	)

	if [[ "$runtime_shell_flag" == "1" ]]; then
		return
	fi
	command -v nix >/dev/null 2>&1 || die "Required command not found: nix"

	script_path="${BASH_SOURCE[0]:-$0}"
	flake_path="$(cd "$(dirname "$script_path")/../../.." && pwd -P)"
	exec nix --quiet --no-warn-dirty shell --inputs-from "$flake_path" \
		"${runtime_packages[@]}" -c env UPDATE_MCPVAULT_IN_NIX_SHELL=1 bash "$script_path" "$@"
}

main() {
	local current

	shopt -s inherit_errexit
	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	current="$(current_version)"
	resolve_version

	if ((REPORT)); then
		print_report "$current"
		return
	fi
	if ((!FORCE)) && [[ "$current" == "$RESOLVED_VERSION" ]]; then
		echo "mcpvault sources.nix already at ${current}; skipping lock regeneration."
		echo "Use --force to regenerate the lock for the pinned version."
		return
	fi

	init_runtime
	trap cleanup EXIT
	stage_lock
	compute_npm_deps_hash
	build_staged >/dev/null
	install_files
	echo "Updated mcpvault ${current} -> ${RESOLVED_VERSION} (npmDepsHash=${NPM_DEPS_HASH})"
}

main "$@"
