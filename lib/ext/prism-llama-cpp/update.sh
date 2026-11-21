#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: lib/ext/prism-llama-cpp/update.sh [--version VERSION] [--file PATH] [--force] [--report] [--ansi|--color=WHEN]
Examples:
  lib/ext/prism-llama-cpp/update.sh
  lib/ext/prism-llama-cpp/update.sh --version prism-b10709-9a9394a
  lib/ext/prism-llama-cpp/update.sh --force
  lib/ext/prism-llama-cpp/update.sh --file lib/ext/prism-llama-cpp/sources.nix
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
	TARGET_FILE="${REPO_ROOT}/lib/ext/prism-llama-cpp/sources.nix"
	REQUESTED_VERSION=""
	FORCE=0
	REPORT=0
	COLOR_MODE="auto"
	RESOLVED_TARGET_FILE=""
	RESOLVED_VERSION=""
	RELEASE_URL=""
	ROCM_HASH=""
	CUDA_HASH=""
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
	local color_code="1;38;2;232;170;117"
	if use_color; then
		printf -- '- \033[%sm%s\033[0m\n' "$color_code" "$line"
	else
		printf -- '- %s\n' "$line"
	fi
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
	local latest_version="$2"

	if [[ "$current_version" == "$latest_version" ]]; then
		echo "- prism-llama-cpp: ${current_version} [latest]"
	else
		print_update_line "prism-llama-cpp: ${current_version} -> ${latest_version}"
	fi
}

print_no_update() {
	local current_version="$1"

	echo "prism-llama-cpp $(basename "$RESOLVED_TARGET_FILE") already at ${current_version}; skipping prefetch."
	echo "Use --force to recompute hashes for the pinned version."
}

github_api() {
	local url="$1"
	local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
	local -a curl_args=(
		-fsSL
		--header "Accept: application/vnd.github+json"
		--header "X-GitHub-Api-Version: 2022-11-28"
		--user-agent "abird-prism-llama-cpp-updater"
	)

	if [[ -n "$token" ]]; then
		[[ "$token" != *[$' \t\r\n']* ]] || die "GITHUB_TOKEN and GH_TOKEN must not contain whitespace"
		curl_args+=(--header "Authorization: Bearer ${token}")
	fi

	curl "${curl_args[@]}" "$url"
}

get_release_metadata() {
	local tag

	if [[ -n "$REQUESTED_VERSION" ]]; then
		RESOLVED_VERSION="${REQUESTED_VERSION#v}"
		RELEASE_URL="https://github.com/PrismML-Eng/llama.cpp/releases/tag/${RESOLVED_VERSION}"
		return
	fi

	# The fork publishes rolling prism-<upstream-build>-<commit> tags without a
	# comparable version ordering, so take the most recent release carrying the
	# fork prefix (the GitHub releases list is newest first).
	if ! tag="$(
		github_api "https://api.github.com/repos/PrismML-Eng/llama.cpp/releases?per_page=50" |
			jq -er '[.[].tag_name | select(startswith("prism-"))][0]'
	)"; then
		die "Could not resolve latest PrismML llama.cpp release tag"
	fi

	RESOLVED_VERSION="$tag"
	RELEASE_URL="https://github.com/PrismML-Eng/llama.cpp/releases/tag/${tag}"
}

prefetch_artifact() {
	local target="$1"
	local hash_var="$2"
	local url hash

	url="https://github.com/PrismML-Eng/llama.cpp/releases/download/${RESOLVED_VERSION}/llama-${RESOLVED_VERSION}-${target}.tar.gz"
	hash="$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -er .hash)"
	printf -v "$hash_var" '%s' "$hash"
}

compute_hashes() {
	prefetch_artifact "bin-ubuntu-rocm-7.2-x64" ROCM_HASH
	prefetch_artifact "bin-linux-cuda-12.8-x64" CUDA_HASH
}

render_file() {
	cat <<EOF
{
  prism-llama-cpp = {
    kind = "github-release";
    owner = "PrismML-Eng";
    repo = "llama.cpp";
    tagPrefix = "";
    # PrismML's rolling fork branch tag: the fork name plus the upstream
    # llama.cpp build it was cut from (b10709) and the fork commit prefix.
    version = "${RESOLVED_VERSION}";
    # Release archives are flat directories of llama-server plus its shared
    # libraries, all linked with RUNPATH \$ORIGIN. They are bind-mounted over a
    # container's /app rather than patched, so only the archive is pinned.
    assets = {
      rocm = {
        target = "bin-ubuntu-rocm-7.2-x64";
        hash = "${ROCM_HASH}";
      };
      cuda = {
        target = "bin-linux-cuda-12.8-x64";
        hash = "${CUDA_HASH}";
      };
    };
  };
}
EOF
}

update_file() {
	local tmp_file

	mkdir -p "${REPO_ROOT}/tmp"
	tmp_file="$(mktemp --suffix=.nix "${REPO_ROOT}/tmp/update-prism-llama-cpp.XXXXXX")"
	render_file >"$tmp_file"
	alejandra "$tmp_file" >/dev/null
	chmod 0644 "$tmp_file"
	mv "$tmp_file" "$RESOLVED_TARGET_FILE"
}

print_summary() {
	cat <<EOF
Updated $(basename "$RESOLVED_TARGET_FILE")
  version=$RESOLVED_VERSION
  rocm hash=$ROCM_HASH
  cuda hash=$CUDA_HASH
  releaseUrl=$RELEASE_URL
EOF
}

ensure_runtime_shell() {
	local runtime_shell_flag="${UPDATE_PRISM_LLAMA_CPP_IN_NIX_SHELL:-0}"
	local script_path
	local flake_path
	local -a runtime_packages=(
		nixpkgs#alejandra
		nixpkgs#coreutils
		nixpkgs#curl
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
	exec nix --quiet --no-warn-dirty shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env UPDATE_PRISM_LLAMA_CPP_IN_NIX_SHELL=1 bash "${script_path}" "$@"
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
		print_report "$current_version" "$RESOLVED_VERSION"
		return
	fi
	if ((!FORCE)) && [[ "$current_version" == "$RESOLVED_VERSION" ]] && has_current_hashes; then
		print_no_update "$current_version"
		return
	fi

	compute_hashes
	update_file
	print_summary
}

main "$@"
