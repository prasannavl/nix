#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: lib/ext/stalwart-cli/update.sh [--version VERSION] [--file PATH]
Examples:
  lib/ext/stalwart-cli/update.sh
  lib/ext/stalwart-cli/update.sh --version 1.0.6
  lib/ext/stalwart-cli/update.sh --file lib/ext/stalwart-cli/default.nix
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
	TARGET_FILE="${REPO_ROOT}/lib/ext/stalwart-cli/default.nix"
	REQUESTED_VERSION=""
	RESOLVED_TARGET_FILE=""
	RESOLVED_VERSION=""
	RELEASE_URL=""
	X64_LINUX_HASH=""
	AARCH64_LINUX_HASH=""
	X64_DARWIN_HASH=""
	AARCH64_DARWIN_HASH=""
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

get_release_metadata() {
	local latest_url

	if [[ -n "$REQUESTED_VERSION" ]]; then
		RESOLVED_VERSION="${REQUESTED_VERSION#v}"
		RELEASE_URL="https://github.com/stalwartlabs/cli/releases/tag/v${RESOLVED_VERSION}"
		return
	fi

	latest_url="$(
		curl -fsSLI -o /dev/null -w "%{url_effective}" \
			"https://github.com/stalwartlabs/cli/releases/latest"
	)"
	[[ "$latest_url" =~ /releases/tag/v([^/]+)$ ]] || die "Could not resolve latest Stalwart CLI release URL: $latest_url"

	RESOLVED_VERSION="${BASH_REMATCH[1]}"
	RELEASE_URL="$latest_url"

	[[ -n "$RESOLVED_VERSION" ]] || die "Could not resolve latest Stalwart CLI version"
}

prefetch_artifact() {
	local target="$1"
	local hash_var="$2"
	local url hash

	url="https://github.com/stalwartlabs/cli/releases/download/v${RESOLVED_VERSION}/stalwart-cli-${target}.tar.xz"
	hash="$(nix store prefetch-file --json --hash-type sha256 "$url" | jq -er .hash)"
	printf -v "$hash_var" '%s' "$hash"
}

compute_hashes() {
	prefetch_artifact "x86_64-unknown-linux-musl" X64_LINUX_HASH
	prefetch_artifact "aarch64-unknown-linux-musl" AARCH64_LINUX_HASH
	prefetch_artifact "x86_64-apple-darwin" X64_DARWIN_HASH
	prefetch_artifact "aarch64-apple-darwin" AARCH64_DARWIN_HASH
}

render_file() {
	cat <<EOF
{
  fetchurl,
  lib,
  stdenvNoCC,
}: let
  pname = "stalwart-cli";
  version = "${RESOLVED_VERSION}";
  platform = stdenvNoCC.hostPlatform.system;
  release =
    {
      x86_64-linux = {
        target = "x86_64-unknown-linux-musl";
        hash = "${X64_LINUX_HASH}";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-musl";
        hash = "${AARCH64_LINUX_HASH}";
      };
      x86_64-darwin = {
        target = "x86_64-apple-darwin";
        hash = "${X64_DARWIN_HASH}";
      };
      aarch64-darwin = {
        target = "aarch64-apple-darwin";
        hash = "${AARCH64_DARWIN_HASH}";
      };
    }.\${
      platform
    };
in
  stdenvNoCC.mkDerivation {
    inherit pname version;

    src = fetchurl {
      url = "https://github.com/stalwartlabs/cli/releases/download/v\${version}/stalwart-cli-\${release.target}.tar.xz";
      hash = release.hash;
    };

    sourceRoot = "stalwart-cli-\${release.target}";

    installPhase = ''
      runHook preInstall
      install -Dm755 stalwart-cli \$out/bin/stalwart-cli
      runHook postInstall
    '';

    meta = {
      description = "Command-line administration tool for Stalwart";
      homepage = "https://github.com/stalwartlabs/cli";
      license = [lib.licenses.agpl3Only];
      mainProgram = "stalwart-cli";
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
    };
  }
EOF
}

update_file() {
	local tmp_file

	mkdir -p "${REPO_ROOT}/tmp"
	tmp_file="$(mktemp "${REPO_ROOT}/tmp/update-stalwart-cli.XXXXXX")"
	render_file >"$tmp_file"
	mv "$tmp_file" "$RESOLVED_TARGET_FILE"
}

print_summary() {
	cat <<EOF
Updated $(basename "$RESOLVED_TARGET_FILE")
  version=$RESOLVED_VERSION
  x86_64-linux hash=$X64_LINUX_HASH
  aarch64-linux hash=$AARCH64_LINUX_HASH
  x86_64-darwin hash=$X64_DARWIN_HASH
  aarch64-darwin hash=$AARCH64_DARWIN_HASH
  releaseUrl=$RELEASE_URL
EOF
}

ensure_runtime_shell() {
	local runtime_shell_flag="${UPDATE_STALWART_CLI_IN_NIX_SHELL:-0}"
	local script_path
	local flake_path
	local -a runtime_packages=(
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
	exec nix --quiet --no-warn-dirty shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env UPDATE_STALWART_CLI_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

main() {
	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	resolve_target_file
	get_release_metadata
	compute_hashes
	update_file
	print_summary
}

main "$@"
