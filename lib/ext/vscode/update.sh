#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: lib/ext/vscode/update.sh [--version VERSION] [--file PATH] [--report] [--ansi|--color=WHEN]
Examples:
  lib/ext/vscode/update.sh
  lib/ext/vscode/update.sh --version 1.112.0
  lib/ext/vscode/update.sh --file lib/ext/vscode/default.nix
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
	TARGET_FILE="${REPO_ROOT}/lib/ext/vscode/default.nix"
	REQUESTED_VERSION=""
	REPORT=0
	COLOR_MODE="auto"
	RESOLVED_TARGET_FILE=""
	RESOLVED_VERSION=""
	RESOLVED_REV=""
	RELEASE_NOTES_URL=""
	X64_SRC_NAME=""
	X64_SRC_HASH=""
	ARM64_SRC_NAME=""
	ARM64_SRC_HASH=""
	DARWIN_ARM64_SRC_NAME=""
	DARWIN_ARM64_SRC_HASH=""
	X64_SERVER_NAME=""
	X64_SERVER_HASH=""
	ARM64_SERVER_NAME=""
	ARM64_SERVER_HASH=""
	DARWIN_ARM64_SERVER_NAME=""
	DARWIN_ARM64_SERVER_HASH=""
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
	[[ -f "$RESOLVED_TARGET_FILE" ]] || die "Target file not found: $RESOLVED_TARGET_FILE"
	sed -nE 's/^[[:space:]]*version = "([^"]+)";.*/\1/p' "$RESOLVED_TARGET_FILE" | head -n1
}

print_report() {
	local current_version="$1"
	local latest_version="$2"

	if [[ "$current_version" == "$latest_version" ]]; then
		echo "- vscode: ${current_version} [latest]"
	else
		print_update_line "vscode: ${current_version} -> ${latest_version}" "$current_version" "$latest_version"
	fi
}

get_release_metadata() {
	local release_key
	local metadata

	release_key="${REQUESTED_VERSION:-latest}"
	metadata="$(curl -fsSL "https://update.code.visualstudio.com/api/update/linux-x64/stable/${release_key}")"
	RESOLVED_VERSION="$(jq -er '.productVersion' <<<"$metadata")"
	RESOLVED_REV="$(jq -er '.version' <<<"$metadata")"
	RELEASE_NOTES_URL="$(jq -r '.releaseNotesUrl // empty' <<<"$metadata")"
	[[ -n "$RESOLVED_VERSION" ]] || die "Could not resolve VS Code version"
	[[ -n "$RESOLVED_REV" ]] || die "Could not resolve VS Code revision"
}

resolve_release_notes_url() {
	local major
	local minor
	local candidate

	if [[ -n "$RELEASE_NOTES_URL" ]]; then
		return
	fi

	IFS=. read -r major minor _ <<<"$RESOLVED_VERSION"
	[[ -n "$major" ]] || return
	[[ -n "$minor" ]] || return

	candidate="https://code.visualstudio.com/updates/v${major}_${minor}"
	if curl -fsI "$candidate" >/dev/null 2>&1; then
		RELEASE_NOTES_URL="$candidate"
	fi
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
	prefetch_artifact "darwin-arm64" DARWIN_ARM64_SRC_NAME DARWIN_ARM64_SRC_HASH

	prefetch_artifact "server-linux-x64" X64_SERVER_NAME X64_SERVER_HASH
	prefetch_artifact "server-linux-arm64" ARM64_SERVER_NAME ARM64_SERVER_HASH
	prefetch_artifact "server-darwin-arm64" DARWIN_ARM64_SERVER_NAME DARWIN_ARM64_SERVER_HASH
}

render_file() {
	cat <<EOF
{
  pkgs,
  commandLineArgs ? "",
  ...
}: let
  version = "${RESOLVED_VERSION}";
  inherit (pkgs.stdenv.hostPlatform) system;
  throwSystem = throw "Unsupported system for vscode-upstream: \${system}";
  plat =
    {
      x86_64-linux = "linux-x64";
      aarch64-linux = "linux-arm64";
      aarch64-darwin = "darwin-arm64";
    }
    .\${
      system
    } or throwSystem;
  srcName =
    {
      x86_64-linux = "${X64_SRC_NAME}";
      aarch64-linux = "${ARM64_SRC_NAME}";
      aarch64-darwin = "${DARWIN_ARM64_SRC_NAME}";
    }
    .\${
      system
    } or throwSystem;
  srcHash =
    {
      x86_64-linux = "${X64_SRC_HASH}";
      aarch64-linux = "${ARM64_SRC_HASH}";
      aarch64-darwin = "${DARWIN_ARM64_SRC_HASH}";
    }
    .\${
      system
    } or throwSystem;
  serverPlat = {
    x86_64-linux = "server-linux-x64";
    aarch64-linux = "server-linux-arm64";
    aarch64-darwin = "server-darwin-arm64";
  };
  serverName = {
    x86_64-linux = "${X64_SERVER_NAME}";
    aarch64-linux = "${ARM64_SERVER_NAME}";
    aarch64-darwin = "${DARWIN_ARM64_SERVER_NAME}";
  };
  serverHash = {
    x86_64-linux = "${X64_SERVER_HASH}";
    aarch64-linux = "${ARM64_SERVER_HASH}";
    aarch64-darwin = "${DARWIN_ARM64_SERVER_HASH}";
  };
  rev = "${RESOLVED_REV}";
  # VS Code now vendors ripgrep under @vscode/ripgrep-universal; keep the
  # package patch aligned so search keeps working after upstream updates.
  ripgrepPath =
    {
      x86_64-linux = "resources/app/node_modules/@vscode/ripgrep-universal/bin/linux-x64/rg";
      aarch64-linux = "resources/app/node_modules/@vscode/ripgrep-universal/bin/linux-arm64/rg";
      aarch64-darwin = "Contents/Resources/app/node_modules/@vscode/ripgrep-universal/bin/darwin-arm64/rg";
    }
    .\${
      system
    } or throwSystem;
in
  (pkgs.unstable.vscode.override {
    inherit commandLineArgs;
  })
  .overrideAttrs (old: let
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
    buildInputs =
      (old.buildInputs or [])
      ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        pkgs.libei
        pkgs.libjpeg8.out
        pkgs.libxtst
        pkgs.pipewire
      ];
    autoPatchelfIgnoreMissingDeps =
      (old.autoPatchelfIgnoreMissingDeps or [])
      ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
        "libc.musl-x86_64.so.1"
        "libc.musl-aarch64.so.1"
        "libc.musl-armv7.so.1"
      ];
    postPatch = builtins.replaceStrings ["resources/app/node_modules/@vscode/ripgrep/bin/rg"] [ripgrepPath] (old.postPatch or "");
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
EOF

	if [[ -n "$RELEASE_NOTES_URL" ]]; then
		cat <<EOF
  releaseNotesUrl=$RELEASE_NOTES_URL
EOF
	fi

	cat <<EOF
  x86_64-linux app name=$X64_SRC_NAME
  x86_64-linux app hash=$X64_SRC_HASH
  aarch64-linux app name=$ARM64_SRC_NAME
  aarch64-linux app hash=$ARM64_SRC_HASH
  aarch64-darwin app name=$DARWIN_ARM64_SRC_NAME
  aarch64-darwin app hash=$DARWIN_ARM64_SRC_HASH
  x86_64-linux server name=$X64_SERVER_NAME
  x86_64-linux server hash=$X64_SERVER_HASH
  aarch64-linux server name=$ARM64_SERVER_NAME
  aarch64-linux server hash=$ARM64_SERVER_HASH
  aarch64-darwin server name=$DARWIN_ARM64_SERVER_NAME
  aarch64-darwin server hash=$DARWIN_ARM64_SERVER_HASH
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
	flake_path="$(cd "$(dirname "${script_path}")/../../.." && pwd -P)"
	exec nix --quiet --no-warn-dirty shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env UPDATE_VSCODE_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

main() {
	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	resolve_target_file
	get_release_metadata
	if ((REPORT)); then
		print_report "$(get_current_version)" "$RESOLVED_VERSION"
		return
	fi

	resolve_release_notes_url
	compute_hashes
	update_file
	print_summary
}

main "$@"
