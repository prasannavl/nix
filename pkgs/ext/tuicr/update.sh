#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: pkgs/ext/tuicr/update.sh [--version VERSION] [--file PATH] [--force] [--report] [--ansi|--color=WHEN]

Examples:
  pkgs/ext/tuicr/update.sh
  pkgs/ext/tuicr/update.sh --version 0.27.0
  pkgs/ext/tuicr/update.sh --force
  pkgs/ext/tuicr/update.sh --report
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
	UNIT_DIR="${REPO_ROOT}/pkgs/ext/tuicr"
	TARGET_FILE="${UNIT_DIR}/sources.nix"
	OWNER="agavra"
	REPO="tuicr"
	TAG_PREFIX="v"
	REQUESTED_VERSION=""
	FORCE=0
	REPORT=0
	COLOR_MODE="auto"
	RUNTIME_DIR=""
	RESOLVED_TARGET_FILE=""
	RESOLVED_VERSION=""
	RESOLVED_TAG=""
	RESOLVED_REV=""
	RESOLVED_HASH=""
	RESOLVED_CARGO_HASH=""
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--version | -v)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			REQUESTED_VERSION="$2"
			shift 2
			;;
		--force)
			FORCE=1
			shift
			;;
		--file | -f)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			TARGET_FILE="$2"
			shift 2
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

resolve_target_file() {
	if [[ "$TARGET_FILE" = /* ]]; then
		RESOLVED_TARGET_FILE="$TARGET_FILE"
	else
		RESOLVED_TARGET_FILE="${REPO_ROOT}/$TARGET_FILE"
	fi
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

	if use_color; then
		printf -- '- \033[1;38;2;232;170;117m%s\033[0m\n' "$line"
	else
		printf -- '- %s\n' "$line"
	fi
}

github_json() {
	local path="$1"
	local -a curl_args=(
		-fsSL
		-H "Accept: application/vnd.github+json"
		-H "X-GitHub-Api-Version: 2022-11-28"
	)

	if [[ -n "${GITHUB_TOKEN:-}" ]]; then
		curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
	fi

	curl "${curl_args[@]}" "https://api.github.com/repos/${OWNER}/${REPO}/${path}"
}

get_current_version() {
	[[ -f "$RESOLVED_TARGET_FILE" ]] || die "Target file not found: $RESOLVED_TARGET_FILE"
	sed -nE 's/^[[:space:]]*version = "([^"]+)";.*/\1/p' "$RESOLVED_TARGET_FILE" | head -n1
}

has_current_hashes() {
	local hash_count

	hash_count="$(grep -oE '"sha256-[^"]+"' "$RESOLVED_TARGET_FILE" | wc -l)"
	((hash_count >= 2))
}

print_report() {
	local current_version="$1"

	if [[ "$current_version" == "$RESOLVED_VERSION" ]]; then
		echo "- tuicr: ${current_version} [latest]"
	else
		print_update_line "tuicr: ${current_version} -> ${RESOLVED_VERSION}"
	fi
}

print_no_update() {
	local current_version="$1"

	echo "tuicr sources.nix already at ${current_version}; skipping prefetch."
	echo "Use --force to recompute the pin."
}

get_release_metadata() {
	local name

	if [[ -n "$REQUESTED_VERSION" ]]; then
		RESOLVED_VERSION="${REQUESTED_VERSION#"$TAG_PREFIX"}"
		RESOLVED_TAG="${TAG_PREFIX}${RESOLVED_VERSION}"
		return
	fi

	name="$(github_json "releases/latest" | jq -er '.tag_name')"
	[[ -n "$name" ]] || die "Could not resolve the latest tuicr release"
	RESOLVED_TAG="$name"
	RESOLVED_VERSION="${name#"$TAG_PREFIX"}"
}

resolve_revision() {
	local tag_object type

	tag_object="$(github_json "git/ref/tags/${RESOLVED_TAG}")"
	type="$(jq -er '.object.type' <<<"$tag_object")"
	if [[ "$type" == "tag" ]]; then
		RESOLVED_REV="$(jq -er '.object.sha' <<<"$tag_object")"
		RESOLVED_REV="$(github_json "git/tags/${RESOLVED_REV}" | jq -er '.object.sha')"
	else
		RESOLVED_REV="$(jq -er '.object.sha' <<<"$tag_object")"
	fi
	[[ "$RESOLVED_REV" =~ ^[0-9a-f]{40}$ ]] || die "Could not resolve a commit for ${RESOLVED_TAG}"
}

prefetch_hash() {
	nix store prefetch-file --json --hash-type sha256 --unpack \
		"https://github.com/${OWNER}/${REPO}/archive/${RESOLVED_REV}.tar.gz" |
		jq -er .hash
}

render_sources() {
	local cargo_hash="$1"

	cat <<EOF
{
  tuicr = {
    kind = "github-tags";
    owner = "${OWNER}";
    repo = "${REPO}";
    tagPrefix = "${TAG_PREFIX}";
    version = "${RESOLVED_VERSION}";
    rev = "${RESOLVED_REV}";
    hash = "${RESOLVED_HASH}";
    cargoHash = "${cargo_hash}";
  };
}
EOF
}

# cargoHash is the fixed-output hash of the vendored crate tree. Derive it by
# building a staged copy of the unit with a placeholder hash and reading the
# mismatch from the repository nixpkgs, so it matches the flake build.
compute_cargo_hash() {
	local staging build_output cargo_hash system

	staging="${RUNTIME_DIR}/cargo-staging"
	mkdir -p "$staging"
	cp "${UNIT_DIR}/default.nix" "$staging/default.nix"
	render_sources "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" >"$staging/sources.nix"

	system="$(nix eval --raw --impure --expr 'builtins.currentSystem')"

	set +e
	build_output="$(
		nix build --impure --no-link --print-out-paths --expr "
      let
        flake = builtins.getFlake (toString ${REPO_ROOT});
        pkgs = flake.inputs.nixpkgs.legacyPackages.${system};
      in
        pkgs.callPackage ${staging} {}
    " 2>&1
	)"
	set -e

	cargo_hash="$(grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' <<<"$build_output" | tail -n1 | awk '{print $2}')"
	[[ -n "$cargo_hash" ]] || {
		printf '%s\n' "$build_output" >&2
		die "Could not determine cargoHash for tuicr"
	}
	printf '%s' "$cargo_hash"
}

update_file() {
	local tmp_file

	mkdir -p "${REPO_ROOT}/tmp"
	tmp_file="$(mktemp --suffix=.nix "${REPO_ROOT}/tmp/update-tuicr.XXXXXX")"
	render_sources "$RESOLVED_CARGO_HASH" >"$tmp_file"
	alejandra "$tmp_file" >/dev/null
	chmod 0644 "$tmp_file"
	mv "$tmp_file" "$RESOLVED_TARGET_FILE"
}

print_summary() {
	cat <<EOF
Updated $(basename "$RESOLVED_TARGET_FILE")
  version=$RESOLVED_VERSION
  rev=$RESOLVED_REV
  hash=$RESOLVED_HASH
  cargoHash=$RESOLVED_CARGO_HASH
  tag=$RESOLVED_TAG
EOF
}

ensure_runtime_shell() {
	local runtime_shell_flag="${UPDATE_TUICR_IN_NIX_SHELL:-0}"
	local script_path
	local flake_path
	local -a runtime_packages=(
		nixpkgs#alejandra
		nixpkgs#bash
		nixpkgs#coreutils
		nixpkgs#curl
		nixpkgs#gnugrep
		nixpkgs#jq
		nixpkgs#nix
	)

	if [[ "$runtime_shell_flag" = "1" ]]; then
		return
	fi

	if ! command -v nix >/dev/null 2>&1; then
		die "Required command not found: nix"
	fi

	script_path="${BASH_SOURCE[0]:-$0}"
	flake_path="$(cd "$(dirname "$script_path")/../../.." && pwd -P)"
	exec nix --quiet --no-warn-dirty shell --inputs-from "$flake_path" \
		"${runtime_packages[@]}" -c env UPDATE_TUICR_IN_NIX_SHELL=1 bash "$script_path" "$@"
}

cleanup() {
	if [[ -n "${RUNTIME_DIR:-}" && -d "$RUNTIME_DIR" ]]; then
		find "$RUNTIME_DIR" -depth -delete
	fi
}

main() {
	local current_version

	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	resolve_target_file
	get_release_metadata
	current_version="$(get_current_version)"

	if ((REPORT)); then
		print_report "$current_version"
		return
	fi
	if ((!FORCE)) && [[ "$current_version" == "$RESOLVED_VERSION" ]] && has_current_hashes; then
		print_no_update "$current_version"
		return
	fi

	mkdir -p "${REPO_ROOT}/tmp"
	RUNTIME_DIR="$(mktemp -d "${REPO_ROOT}/tmp/update-tuicr.XXXXXX")"
	trap cleanup EXIT

	resolve_revision
	RESOLVED_HASH="$(prefetch_hash)"
	RESOLVED_CARGO_HASH="$(compute_cargo_hash)"
	update_file
	print_summary
}

main "$@"
