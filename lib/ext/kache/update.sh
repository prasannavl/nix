#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	printf '%s\n' 'Usage: lib/ext/kache/update.sh [--version VERSION] [--file PATH] [--force] [--report] [--ansi|--color=WHEN]'
}

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
	REPOSITORY_URL="https://github.com/kunobi-ninja/kache"
	TARGET_FILE="${REPO_ROOT}/lib/ext/kache/sources.nix"
	REQUESTED_VERSION=""
	FORCE=0
	REPORT=0
	COLOR_MODE=auto
}

parse_args() {
	while (($#)); do
		case "$1" in
		--version | -v)
			[[ ${2:-} =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$1 requires a stable version (X.Y.Z)"
			REQUESTED_VERSION="${2#v}"
			shift
			;;
		--file | -f)
			[[ -n ${2:-} ]] || die "$1 requires a path"
			TARGET_FILE="$2"
			shift
			;;
		--force) FORCE=1 ;;
		--report) REPORT=1 ;;
		--color | --ansi) COLOR_MODE=always ;;
		--color=*) COLOR_MODE="${1#*=}" ;;
		--help | -h)
			usage
			exit 0
			;;
		*) die "Unknown argument: $1" ;;
		esac
		shift
	done
	case "$COLOR_MODE" in
	auto | always | never) ;;
	*) die "--color must be one of: auto, always, never" ;;
	esac
	[[ "$TARGET_FILE" = /* ]] || TARGET_FILE="${REPO_ROOT}/${TARGET_FILE}"
	[[ -f "$TARGET_FILE" ]] || die "Target file not found: $TARGET_FILE"
}

latest_version() {
	local url tag
	url="$(curl -fsSLI --connect-timeout 10 --max-time 30 -o /dev/null -w '%{url_effective}' "$REPOSITORY_URL/releases/latest")"
	tag="${url#"$REPOSITORY_URL/releases/tag/v"}"
	[[ "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not resolve latest stable Kache release"
	printf '%s\n' "$tag"
}

print_report() {
	local current="$1" candidate="$2"
	if [[ "$current" == "$candidate" ]]; then
		printf -- '- kache: %s [latest]\n' "$current"
	elif [[ "$COLOR_MODE" == always || ("$COLOR_MODE" == auto && -t 1) ]]; then
		printf -- '- \033[1;38;2;232;170;117mkache: %s -> %s\033[0m\n' "$current" "$candidate"
	else
		printf -- '- kache: %s -> %s\n' "$current" "$candidate"
	fi
}

prefetch_hash() {
	local version="$1" arch="$2" archive url record checksum filename extra
	archive="kache-${arch}-unknown-linux-musl.tar.gz"
	url="$REPOSITORY_URL/releases/download/v$version/$archive"
	record="$(curl -fsSL --connect-timeout 10 --max-time 30 "$url.sha256")"
	read -r checksum filename extra <<<"$record"
	[[ "$record" != *$'\n'* && "$checksum" =~ ^[[:xdigit:]]{64}$ && "${filename#\*}" == "$archive" && -z "$extra" ]] ||
		die "Invalid release checksum for $archive"
	nix store prefetch-file --json --hash-type sha256 --expected-hash "$checksum" "$url" |
		jq -er '.hash | select(test("^sha256-[A-Za-z0-9+/]{43}=$"))'
}

write_sources() (
	local version="$1" x64="$2" arm64="$3" staged
	# Stage beside the destination so rename is atomic, including --file.
	staged="$(mktemp --suffix=.nix "$(dirname "$TARGET_FILE")/.kache-sources.XXXXXX")"
	trap 'rm -f -- "$staged"' EXIT
	cat >"$staged" <<EOF
{
  kache = {
    kind = "github-release";
    owner = "kunobi-ninja";
    repo = "kache";
    tagPrefix = "v";
    version = "$version";
    releases = {
      x86_64-linux = {
        target = "x86_64-unknown-linux-musl";
        hash = "$x64";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-musl";
        hash = "$arm64";
      };
    };
  };
}
EOF
	alejandra --quiet "$staged"
	chmod 0644 "$staged"
	mv -T -- "$staged" "$TARGET_FILE"
)

ensure_runtime_shell() {
	local script repo_root
	[[ ${UPDATE_KACHE_IN_NIX_SHELL:-0} == 1 ]] && return 0
	command -v nix >/dev/null || die 'Required command not found: nix'
	script="${BASH_SOURCE[0]}"
	repo_root="$(cd "$(dirname "$script")/../../.." && pwd -P)"
	exec nix --quiet --no-warn-dirty shell --inputs-from "$repo_root" \
		nixpkgs#alejandra nixpkgs#coreutils nixpkgs#curl nixpkgs#jq \
		-c env UPDATE_KACHE_IN_NIX_SHELL=1 bash "$script" "$@"
}

main() {
	local pin current candidate x64 arm64
	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	pin="$(nix eval --json --file "$TARGET_FILE" kache)"
	current="$(jq -er '.version | strings' <<<"$pin")"
	candidate="${REQUESTED_VERSION:-$(latest_version)}"
	if ((REPORT)); then
		print_report "$current" "$candidate"
	elif ((!FORCE)) && [[ "$current" == "$candidate" ]] && jq -e '
		[.releases["x86_64-linux"].hash, .releases["aarch64-linux"].hash]
		| all((. // "") | test("^sha256-[A-Za-z0-9+/]{43}=$"))
	' <<<"$pin" >/dev/null; then
		printf 'Kache already at %s; skipping prefetch (use --force to recheck hashes).\n' "$current"
	else
		x64="$(prefetch_hash "$candidate" x86_64)"
		arm64="$(prefetch_hash "$candidate" aarch64)"
		write_sources "$candidate" "$x64" "$arm64"
		printf 'Updated kache: %s -> %s (%s)\n' "$current" "$candidate" "$TARGET_FILE"
	fi
}

main "$@"
