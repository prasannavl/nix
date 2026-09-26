#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: lib/ext/revdiff/update.sh [--version VERSION] [--file PATH] [--force] [--report] [--ansi|--color=WHEN]

Updates the pinned revdiff revision, source hash, and packaged Pi extension
version. --version accepts a bare version or the tag form.

Examples:
  lib/ext/revdiff/update.sh
  lib/ext/revdiff/update.sh --version 1.13.0
  lib/ext/revdiff/update.sh --force
  lib/ext/revdiff/update.sh --file lib/ext/revdiff/sources.nix
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
	TARGET_FILE="${REPO_ROOT}/lib/ext/revdiff/sources.nix"
	REQUESTED_VERSION=""
	FORCE=0
	REPORT=0
	COLOR_MODE="auto"
	RESOLVED_TARGET_FILE=""
	OWNER=""
	REPO=""
	TAG_PREFIX=""
	CURRENT_VERSION=""
	CURRENT_REV=""
	RESOLVED_VERSION=""
	RESOLVED_TAG=""
	RESOLVED_REV=""
	RESOLVED_HASH=""
	RESOLVED_PI_VERSION=""
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

load_sources() {
	local sources_json

	[[ -f "$RESOLVED_TARGET_FILE" ]] || die "Target file not found: $RESOLVED_TARGET_FILE"
	sources_json="$(nix eval --json --file "$RESOLVED_TARGET_FILE")"
	OWNER="$(jq -er '.revdiff.owner' <<<"$sources_json")"
	REPO="$(jq -er '.revdiff.repo' <<<"$sources_json")"
	TAG_PREFIX="$(jq -r '.revdiff.tagPrefix // "v"' <<<"$sources_json")"
	CURRENT_VERSION="$(jq -er '.revdiff.version' <<<"$sources_json")"
	CURRENT_REV="$(jq -er '.revdiff.rev' <<<"$sources_json")"
}

strip_prefix() {
	local tag="$1"

	if [[ -n "$TAG_PREFIX" && "$tag" == "$TAG_PREFIX"* ]]; then
		printf '%s' "${tag#"$TAG_PREFIX"}"
	else
		printf '%s' "$tag"
	fi
}

get_release_metadata() {
	local name

	if [[ -n "$REQUESTED_VERSION" ]]; then
		RESOLVED_VERSION="$(strip_prefix "$REQUESTED_VERSION")"
		RESOLVED_TAG="${TAG_PREFIX}${RESOLVED_VERSION}"
		return
	fi

	name="$(
		github_json "tags?per_page=100" |
			jq -er '.[].name' |
			grep -E '^[vV]?[0-9]' |
			sort -V |
			tail -n1
	)"
	[[ -n "$name" ]] || die "Could not resolve the latest revdiff tag"
	RESOLVED_TAG="$name"
	RESOLVED_VERSION="$(strip_prefix "$name")"
}

resolve_revision() {
	local tag_object type

	tag_object="$(github_json "git/ref/tags/${RESOLVED_TAG}")"
	type="$(jq -er '.object.type' <<<"$tag_object")"
	if [[ "$type" == "tag" ]]; then
		RESOLVED_REV="$(jq -er --arg tag "$RESOLVED_TAG" '.object.sha' <<<"$tag_object")"
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

resolve_pi_version() {
	curl -fsSL \
		"https://raw.githubusercontent.com/${OWNER}/${REPO}/${RESOLVED_REV}/package.json" |
		jq -er .version
}

print_report() {
	if [[ "$CURRENT_VERSION" == "$RESOLVED_VERSION" && "$CURRENT_REV" == "$RESOLVED_REV" ]]; then
		echo "- revdiff: ${CURRENT_VERSION} [latest]"
	else
		print_update_line "revdiff: ${CURRENT_VERSION} -> ${RESOLVED_VERSION}"
	fi
}

print_no_update() {
	echo "revdiff sources.nix already at ${CURRENT_VERSION} (${CURRENT_REV:0:12}); skipping prefetch."
	echo "Use --force to recompute the pin."
}

render_file() {
	cat <<EOF
{
  revdiff = {
    kind = "github-tags";
    owner = "${OWNER}";
    repo = "${REPO}";
    tagPrefix = "${TAG_PREFIX}";
    version = "${RESOLVED_VERSION}";
    rev = "${RESOLVED_REV}";
    hash = "${RESOLVED_HASH}";
    piVersion = "${RESOLVED_PI_VERSION}";
  };
}
EOF
}

update_file() {
	local tmp_file

	mkdir -p "${REPO_ROOT}/tmp"
	tmp_file="$(mktemp --suffix=.nix "${REPO_ROOT}/tmp/update-revdiff.XXXXXX")"
	render_file >"$tmp_file"
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
  piVersion=$RESOLVED_PI_VERSION
  tag=$RESOLVED_TAG
EOF
}

ensure_runtime_shell() {
	local runtime_shell_flag="${UPDATE_REVDIFF_IN_NIX_SHELL:-0}"
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
		"${runtime_packages[@]}" -c env UPDATE_REVDIFF_IN_NIX_SHELL=1 bash "$script_path" "$@"
}

main() {
	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	resolve_target_file
	load_sources
	get_release_metadata

	if ((REPORT)); then
		resolve_revision
		print_report
		return
	fi

	resolve_revision
	if ((!FORCE)) && [[ "$CURRENT_VERSION" == "$RESOLVED_VERSION" && "$CURRENT_REV" == "$RESOLVED_REV" ]]; then
		print_no_update
		return
	fi

	RESOLVED_HASH="$(prefetch_hash)"
	RESOLVED_PI_VERSION="$(resolve_pi_version)"
	update_file
	print_summary
}

main "$@"
