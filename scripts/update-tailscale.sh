#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: update-tailscale.sh [--version VERSION] [--file PATH]
Examples:
  update-tailscale.sh
  update-tailscale.sh --version 1.96.4
  update-tailscale.sh --file lib/ext/tailscale-upstream.nix
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd -P)"
	TARGET_FILE="${REPO_ROOT}/lib/ext/tailscale-upstream.nix"
	REQUESTED_VERSION=""
	RESOLVED_TARGET_FILE=""
	RESOLVED_VERSION=""
	RELEASE_URL=""
	SRC_HASH=""
	VENDOR_HASH=""
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
	local metadata
	local tag

	if [[ -n "$REQUESTED_VERSION" ]]; then
		RESOLVED_VERSION="${REQUESTED_VERSION#v}"
		RELEASE_URL="https://github.com/tailscale/tailscale/releases/tag/v${RESOLVED_VERSION}"
		return
	fi

	metadata="$(curl -fsSL "https://api.github.com/repos/tailscale/tailscale/releases/latest")"
	tag="$(jq -er '.tag_name' <<<"$metadata")"
	RESOLVED_VERSION="${tag#v}"
	RELEASE_URL="$(jq -r '.html_url // empty' <<<"$metadata")"

	[[ -n "$RESOLVED_VERSION" ]] || die "Could not resolve latest Tailscale version"
}

prefetch_source_hash() {
	local url

	url="https://github.com/tailscale/tailscale/archive/refs/tags/v${RESOLVED_VERSION}.tar.gz"
	SRC_HASH="$(
		nix store prefetch-file --json --hash-type sha256 --unpack "$url" \
			| jq -er .hash
	)"
}

render_fake_vendor_expr() {
	cat <<EOF
let
  flake = builtins.getFlake "${REPO_ROOT}";
  pkgs = import flake.inputs.nixpkgs {
    system = builtins.currentSystem;
    config.allowUnfree = true;
    overlays = import ${REPO_ROOT}/overlays/default.nix { inputs = flake.inputs; };
  };
  version = "${RESOLVED_VERSION}";
in
  pkgs.unstable.tailscale.overrideAttrs (finalAttrs: old: {
    version = version;
    src = pkgs.fetchFromGitHub {
      owner = "tailscale";
      repo = "tailscale";
      tag = "v\${version}";
      hash = "${SRC_HASH}";
    };
    vendorHash = pkgs.lib.fakeHash;
    ldflags =
      builtins.map
      (flag:
        if pkgs.lib.hasPrefix "-X tailscale.com/version." flag
        then
          pkgs.lib.replaceStrings
          [old.version]
          [finalAttrs.version]
          flag
        else flag)
      old.ldflags;
  })
EOF
}

compute_vendor_hash() {
	local build_output
	local expr_file

	mkdir -p "${REPO_ROOT}/tmp"
	expr_file="$(mktemp "${REPO_ROOT}/tmp/update-tailscale-expr.XXXXXX.nix")"
	render_fake_vendor_expr >"$expr_file"

	set +e
	build_output="$(nix build --impure --expr "import ${expr_file}" --no-link --print-out-paths 2>&1)"
	local build_status=$?
	set -e

	rm -f "$expr_file"

	if [[ $build_status -eq 0 ]]; then
		die "Expected fake vendorHash build to fail, but it succeeded"
	fi

	VENDOR_HASH="$(awk '/got:[[:space:]]+sha256-/ {print $2}' <<<"$build_output" | tail -n1)"
	[[ -n "$VENDOR_HASH" ]] || die "Could not parse vendorHash from nix build output"
}

render_file() {
	cat <<EOF
{
  pkgs,
  tailscale,
  ...
}: let
  version = "${RESOLVED_VERSION}";
in
  tailscale.overrideAttrs (finalAttrs: old: {
    version = version;

    src = pkgs.fetchFromGitHub {
      owner = "tailscale";
      repo = "tailscale";
      tag = "v\${version}";
      hash = "${SRC_HASH}";
    };

    vendorHash = "${VENDOR_HASH}";

    ldflags =
      builtins.map
      (flag:
        if pkgs.lib.hasPrefix "-X tailscale.com/version." flag
        then
          pkgs.lib.replaceStrings
          [old.version]
          [finalAttrs.version]
          flag
        else flag)
      old.ldflags;
  })
EOF
}

update_file() {
	local tmp_file

	mkdir -p "${REPO_ROOT}/tmp"
	tmp_file="$(mktemp "${REPO_ROOT}/tmp/update-tailscale.XXXXXX")"
	render_file >"$tmp_file"
	mv "$tmp_file" "$RESOLVED_TARGET_FILE"
}

print_summary() {
	cat <<EOF
Updated $(basename "$RESOLVED_TARGET_FILE")
  version=$RESOLVED_VERSION
  srcHash=$SRC_HASH
  vendorHash=$VENDOR_HASH
  releaseUrl=$RELEASE_URL
EOF
}

ensure_runtime_shell() {
	local runtime_shell_flag="${UPDATE_TAILSCALE_IN_NIX_SHELL:-0}"
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
	exec nix shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env UPDATE_TAILSCALE_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

main() {
	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	resolve_target_file
	get_release_metadata
	prefetch_source_hash
	compute_vendor_hash
	update_file
	print_summary
}

main "$@"
