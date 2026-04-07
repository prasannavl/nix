#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: update-vscode.sh [--version VERSION] [--file PATH]
Examples:
  update-vscode.sh
  update-vscode.sh --version 1.112.0
  update-vscode.sh --file pkgs/ext/vscode-upstream.nix
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
	TARGET_FILE="${REPO_ROOT}/pkgs/ext/vscode-upstream.nix"
	REQUESTED_VERSION=""
	RESOLVED_TARGET_FILE=""
	RESOLVED_VERSION=""
	RESOLVED_REV=""
	X64_SRC_NAME=""
	X64_SRC_HASH=""
	ARM64_SRC_NAME=""
	ARM64_SRC_HASH=""
	DARWIN_SRC_NAME=""
	DARWIN_SRC_HASH=""
	DARWIN_ARM64_SRC_NAME=""
	DARWIN_ARM64_SRC_HASH=""
	ARMHF_SRC_NAME=""
	ARMHF_SRC_HASH=""
	X64_SERVER_NAME=""
	X64_SERVER_HASH=""
	ARM64_SERVER_NAME=""
	ARM64_SERVER_HASH=""
	DARWIN_SERVER_NAME=""
	DARWIN_SERVER_HASH=""
	DARWIN_ARM64_SERVER_NAME=""
	DARWIN_ARM64_SERVER_HASH=""
	ARMHF_SERVER_NAME=""
	ARMHF_SERVER_HASH=""
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
	local release_key
	local metadata

	release_key="${REQUESTED_VERSION:-latest}"
	metadata="$(curl -fsSL "https://update.code.visualstudio.com/api/update/linux-x64/stable/${release_key}")"
	RESOLVED_VERSION="$(jq -er '.productVersion' <<<"$metadata")"
	RESOLVED_REV="$(jq -er '.version' <<<"$metadata")"
	[[ -n "$RESOLVED_VERSION" ]] || die "Could not resolve VS Code version"
	[[ -n "$RESOLVED_REV" ]] || die "Could not resolve VS Code revision"
}

prefetch_artifact() {
	local platform="$1"
	local name_var="$2"
	local hash_var="$3"
	local headers
	local location
	local sha256_hex
	local sri

	headers="$(curl -fsSI "https://update.code.visualstudio.com/commit:${RESOLVED_REV}/${platform}/stable")"
	location="$(awk 'BEGIN{IGNORECASE=1} /^location:/ {sub(/\r$/, "", $2); print $2}' <<<"$headers")"
	sha256_hex="$(awk 'BEGIN{IGNORECASE=1} /^x-sha256:/ {sub(/\r$/, "", $2); print $2}' <<<"$headers")"

	[[ -n "$location" ]] || die "Missing location header for ${platform}"
	[[ -n "$sha256_hex" ]] || die "Missing x-sha256 header for ${platform}"

	sri="$(nix hash convert --hash-algo sha256 --to sri "$sha256_hex")"

	printf -v "$name_var" '%s' "$(basename "$location")"
	printf -v "$hash_var" '%s' "$sri"
}

compute_hashes() {
	prefetch_artifact "linux-x64" X64_SRC_NAME X64_SRC_HASH
	prefetch_artifact "linux-arm64" ARM64_SRC_NAME ARM64_SRC_HASH
	prefetch_artifact "darwin" DARWIN_SRC_NAME DARWIN_SRC_HASH
	prefetch_artifact "darwin-arm64" DARWIN_ARM64_SRC_NAME DARWIN_ARM64_SRC_HASH
	prefetch_artifact "linux-armhf" ARMHF_SRC_NAME ARMHF_SRC_HASH

	prefetch_artifact "server-linux-x64" X64_SERVER_NAME X64_SERVER_HASH
	prefetch_artifact "server-linux-arm64" ARM64_SERVER_NAME ARM64_SERVER_HASH
	prefetch_artifact "server-darwin" DARWIN_SERVER_NAME DARWIN_SERVER_HASH
	prefetch_artifact "server-darwin-arm64" DARWIN_ARM64_SERVER_NAME DARWIN_ARM64_SERVER_HASH
	prefetch_artifact "server-linux-armhf" ARMHF_SERVER_NAME ARMHF_SERVER_HASH
}

render_file() {
	cat <<EOF
{pkgs, ...}: let
  version = "${RESOLVED_VERSION}";
  inherit (pkgs.stdenv.hostPlatform) system;
  throwSystem = throw "Unsupported system for vscode-upstream: \${system}";
  plat =
    {
      x86_64-linux = "linux-x64";
      x86_64-darwin = "darwin";
      aarch64-linux = "linux-arm64";
      aarch64-darwin = "darwin-arm64";
      armv7l-linux = "linux-armhf";
    }
    .\${
      system
    } or throwSystem;
  srcName =
    {
      x86_64-linux = "${X64_SRC_NAME}";
      x86_64-darwin = "${DARWIN_SRC_NAME}";
      aarch64-linux = "${ARM64_SRC_NAME}";
      aarch64-darwin = "${DARWIN_ARM64_SRC_NAME}";
      armv7l-linux = "${ARMHF_SRC_NAME}";
    }
    .\${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "${X64_SRC_HASH}";
      x86_64-darwin = "${DARWIN_SRC_HASH}";
      aarch64-linux = "${ARM64_SRC_HASH}";
      aarch64-darwin = "${DARWIN_ARM64_SRC_HASH}";
      armv7l-linux = "${ARMHF_SRC_HASH}";
    }
    .\${
      system
    } or throwSystem;
  serverPlat = {
    x86_64-linux = "server-linux-x64";
    x86_64-darwin = "server-darwin";
    aarch64-linux = "server-linux-arm64";
    aarch64-darwin = "server-darwin-arm64";
    armv7l-linux = "server-linux-armhf";
  };
  serverName = {
    x86_64-linux = "${X64_SERVER_NAME}";
    x86_64-darwin = "${DARWIN_SERVER_NAME}";
    aarch64-linux = "${ARM64_SERVER_NAME}";
    aarch64-darwin = "${DARWIN_ARM64_SERVER_NAME}";
    armv7l-linux = "${ARMHF_SERVER_NAME}";
  };
  serverHash = {
    x86_64-linux = "${X64_SERVER_HASH}";
    x86_64-darwin = "${DARWIN_SERVER_HASH}";
    aarch64-linux = "${ARM64_SERVER_HASH}";
    aarch64-darwin = "${DARWIN_ARM64_SERVER_HASH}";
    armv7l-linux = "${ARMHF_SERVER_HASH}";
  };
  rev = "${RESOLVED_REV}";
in
  pkgs.unstable.vscode.overrideAttrs (old: let
    vscodeServers =
      pkgs.lib.mapAttrs
      (serverSystem: serverArchiveName:
        pkgs.srcOnly {
          name = "\${serverArchiveName}-\${rev}";
          src = pkgs.fetchurl {
            name = serverArchiveName;
            url = "https://update.code.visualstudio.com/commit:\${rev}/\${serverPlat.\${serverSystem}}/stable";
            hash = serverHash.\${serverSystem};
          };
          stdenv = pkgs.stdenvNoCC;
        })
      serverName;
  in {
    inherit rev version;
    passthru =
      old.passthru
      // {
        vscodeVersion = version;
        inherit vscodeServers;
      };
    src = pkgs.fetchurl {
      name = srcName;
      url = "https://update.code.visualstudio.com/commit:\${rev}/\${plat}/stable";
      hash = srcHash;
    };
    vscodeServer = vscodeServers.x86_64-linux;
  })
EOF
}

update_file() {
	mkdir -p "${REPO_ROOT}/tmp"
	local tmp_file
	tmp_file="$(mktemp "${REPO_ROOT}/tmp/update-vscode.XXXXXX")"

	render_file >"$tmp_file"
	mv "$tmp_file" "$RESOLVED_TARGET_FILE"
}

print_summary() {
	cat <<EOF
Updated $(basename "$RESOLVED_TARGET_FILE")
  version=$RESOLVED_VERSION
  rev=$RESOLVED_REV
  x86_64-linux app name=$X64_SRC_NAME
  x86_64-linux app hash=$X64_SRC_HASH
  aarch64-linux app name=$ARM64_SRC_NAME
  aarch64-linux app hash=$ARM64_SRC_HASH
  x86_64-darwin app name=$DARWIN_SRC_NAME
  x86_64-darwin app hash=$DARWIN_SRC_HASH
  aarch64-darwin app name=$DARWIN_ARM64_SRC_NAME
  aarch64-darwin app hash=$DARWIN_ARM64_SRC_HASH
  armv7l-linux app name=$ARMHF_SRC_NAME
  armv7l-linux app hash=$ARMHF_SRC_HASH
  x86_64-linux server name=$X64_SERVER_NAME
  x86_64-linux server hash=$X64_SERVER_HASH
  aarch64-linux server name=$ARM64_SERVER_NAME
  aarch64-linux server hash=$ARM64_SERVER_HASH
  x86_64-darwin server name=$DARWIN_SERVER_NAME
  x86_64-darwin server hash=$DARWIN_SERVER_HASH
  aarch64-darwin server name=$DARWIN_ARM64_SERVER_NAME
  aarch64-darwin server hash=$DARWIN_ARM64_SERVER_HASH
  armv7l-linux server name=$ARMHF_SERVER_NAME
  armv7l-linux server hash=$ARMHF_SERVER_HASH
EOF
}

ensure_runtime_shell() {
	local runtime_shell_flag="${UPDATE_VSCODE_IN_NIX_SHELL:-0}"
	local script_path
	local flake_path
	local -a runtime_packages=(
		nixpkgs#coreutils
		nixpkgs#curl
		nixpkgs#gawk
		nixpkgs#jq
	)

	if [ "$runtime_shell_flag" = "1" ]; then
		return
	fi

	if ! command -v nix >/dev/null 2>&1; then
		die "Required command not found: nix"
	fi

	script_path="${BASH_SOURCE[0]:-$0}"
	flake_path="$(cd "$(dirname "${script_path}")/.." && pwd -P)"
	exec nix shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env UPDATE_VSCODE_IN_NIX_SHELL=1 bash "${script_path}" "$@"
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
