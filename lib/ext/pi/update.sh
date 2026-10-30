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
	SOURCES_FILE="${PI_DIR}/sources.nix"
	REQUESTED_VERSION=""
	FORCE=0
	REPORT=0
	COLOR_MODE="auto"
	CHANGED=0
	RUNTIME_DIR=""
	NPM_CACHE=""
	STAGING_DIR=""
	WORKING_SOURCES=""
	SOURCES_JSON=""
	ALL_PACKAGES=()
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

github_repo() {
	jq -er --arg package "$1" '.[$package] | "\(.owner) \(.repo)"' <<<"$SOURCES_JSON"
}

current_version() {
	jq -er --arg package "$1" '.[$package].version' <<<"$SOURCES_JSON"
}

deps_resolver() {
	jq -r --arg package "$1" '.[$package].depsResolver // empty' <<<"$SOURCES_JSON"
}

resolve_metadata() {
	local package="$1"
	local registry_name selector

	registry_name="$(jq -er --arg package "$package" '.[$package].package' <<<"$SOURCES_JSON")"
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

	[[ "$url" == https://* ]] || die "Expected HTTPS source URL"

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
      | if $srcHash != "" then .[$package].srcHash = $srcHash else . end
      | if $rev != "" then .[$package].rev = $rev else . end
      | if $releaseHash != "" then .[$package].releaseHash = $releaseHash else . end
      | if $npmDepsHash != "" then .[$package].npmDepsHash = $npmDepsHash else . end
    ' \
		"$WORKING_SOURCES" >"$next_file"
	mv "$next_file" "$WORKING_SOURCES"
	write_staged_sources
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
	write_staged_sources
}

render_sources() {
	local package field value
	local -a fields=(kind package owner repo version rev srcHash releaseHash npmDepsHash depsResolver)

	echo "{"
	for package in "${ALL_PACKAGES[@]}"; do
		printf '  %s = {\n' "$(jq -nr --arg value "$package" '$value | tojson | gsub("\\$\\{"; "\\${")')"
		for field in "${fields[@]}"; do
			value="$(jq -r --arg package "$package" --arg field "$field" '.[$package][$field] // empty | tojson | gsub("\\$\\{"; "\\${")' "$WORKING_SOURCES")"
			[[ -n "$value" ]] && printf '    %s = %s;\n' "$field" "$value"
		done
		if jq -e --arg package "$package" '.[$package] | has("deps")' "$WORKING_SOURCES" >/dev/null; then
			echo "    deps = {"
			jq -r --arg package "$package" '
				def nix_string: tojson | gsub("\\$\\{"; "\\${");
				.[$package].deps | to_entries | sort_by(.key)[]
				| "      \(.key | nix_string) = {\n"
				  + "        kind = \(.value.kind | nix_string);\n"
				  + "        range = \(.value.range | nix_string);\n"
				  + "        version = \(.value.version | nix_string);\n"
				  + "        srcHash = \(.value.srcHash | nix_string);\n"
				  + "      };"
			' "$WORKING_SOURCES"
			echo "    };"
		fi
		echo "  };"
		[[ "$package" != "${ALL_PACKAGES[-1]}" ]] && echo
	done
	echo "}"
}

write_staged_sources() {
	local next_file="${STAGING_DIR}/sources.next.nix"

	render_sources >"$next_file"
	alejandra "$next_file" >/dev/null
	chmod 0644 "$next_file"
	mv "$next_file" "${STAGING_DIR}/sources.nix"
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

init_target_platform() {
	local system

	TARGET_LIBC="${TARGET_LIBC:-glibc}"
	if [[ -n "${TARGET_OS:-}" ]]; then
		[[ -n "${TARGET_CPU:-}" ]] || die "TARGET_OS requires TARGET_CPU"
		return 0
	fi
	system="$(nix eval --impure --raw --expr builtins.currentSystem)"
	TARGET_CPU="${system%%-*}"
	TARGET_OS="${system#*-}"
	case "$TARGET_CPU" in
	x86_64) TARGET_CPU=x64 ;;
	aarch64) TARGET_CPU=arm64 ;;
	esac
}

# Pi supplies these modules to every extension, so they are never pinned.
is_host_module() {
	case "$1" in
	@earendil-works/pi-ai | @earendil-works/pi-agent-core | @earendil-works/pi-coding-agent | @earendil-works/pi-tui | \
		@mariozechner/pi-ai | @mariozechner/pi-agent-core | @mariozechner/pi-coding-agent | @mariozechner/pi-tui | \
		typebox | @sinclair/typebox) return 0 ;;
	*) return 1 ;;
	esac
}

npm_manifest() {
	npm --cache "$NPM_CACHE" --loglevel=silent view "$1" --json
}

# Highest published version satisfying a declared range.
resolve_range_version() {
	npm --cache "$NPM_CACHE" --loglevel=silent view "$1@$2" version --json |
		jq -er 'if type == "array" then last else . end'
}

# Honor npm allow/deny lists; infer missing native-platform metadata from names.
dep_supports_platform() {
	local name="$1" manifest="$2" os cpu

	jq -e --arg os "$TARGET_OS" --arg cpu "$TARGET_CPU" --arg libc "${TARGET_LIBC:-glibc}" '
		def supports($target):
			(if type == "string" then [.] else . end) as $values
			| ($values | map(select(startswith("!") | not))) as $positive
			| ($values | index("!" + $target)) == null
			and (($positive | length) == 0 or ($positive | index($target)) != null
				or ($positive | index("any")) != null);
		(.os // [] | supports($os)) and (.cpu // [] | supports($cpu))
		and (.libc // [] | supports($libc))
	' <<<"$manifest" >/dev/null || return 1
	if jq -e '(.os // [] | length) == 0' <<<"$manifest" >/dev/null &&
		[[ "$name" =~ -(linux|win32|win|darwin|android|freebsd)(-|$) ]]; then
		os="${BASH_REMATCH[1]}"
		[[ "$os" != win ]] || os=win32
		[[ "$os" == "$TARGET_OS" ]] || return 1
	fi
	if jq -e '(.cpu // [] | length) == 0' <<<"$manifest" >/dev/null &&
		[[ "$name" =~ -(x86_64|aarch64|arm64|x64|ia32|x32|arm)(-|$) ]]; then
		cpu="${BASH_REMATCH[1]}"
		case "$cpu" in
		x86_64) cpu=x64 ;;
		aarch64) cpu=arm64 ;;
		x32) cpu=ia32 ;;
		esac
		[[ "$cpu" == "$TARGET_CPU" ]] || return 1
	fi
	if [[ "$TARGET_OS" == linux ]] && jq -e '(.libc // [] | length) == 0' <<<"$manifest" >/dev/null; then
		if [[ "$name" =~ -musl(-|$) && "${TARGET_LIBC:-glibc}" != musl ]]; then return 1; fi
		if [[ "$name" =~ -gnu(-|$) && "${TARGET_LIBC:-glibc}" != glibc ]]; then return 1; fi
	fi
	return 0
}

# Queue helpers append to DEP_NAMES/DEP_RANGES, read by resolve_deps.
enqueue_dependencies() {
	local manifest="$1" name range entries

	entries="$(jq -r '
		(.optionalDependencies // {}) as $optional
		| (.dependencies // {}) | to_entries[] | .key as $name
		| select($optional | has($name) | not)
		| if (.value | type) != "string" then error("invalid dependency range")
		  else [.key, .value] | @tsv end
	' <<<"$manifest")" || die "Invalid dependency metadata"
	while IFS=$'\t' read -r name range; do
		[[ -n "$name" ]] || continue
		is_host_module "$name" && continue
		DEP_NAMES+=("$name")
		DEP_RANGES+=("$range")
	done <<<"$entries"
}

enqueue_optional_dependencies() {
	local manifest="$1" name range resolved candidate entries

	entries="$(jq -r '
		(.optionalDependencies // {}) | to_entries[]
		| if (.value | type) != "string" then error("invalid optional dependency range")
		  else [.key, .value] | @tsv end
	' <<<"$manifest")" || die "Invalid optional dependency metadata"
	while IFS=$'\t' read -r name range; do
		[[ -n "$name" ]] || continue
		is_host_module "$name" && continue
		resolved="$(resolve_range_version "$name" "$range" 2>/dev/null || true)"
		[[ -n "$resolved" ]] || continue
		candidate="$(npm_manifest "${name}@${resolved}" 2>/dev/null)" || continue
		dep_supports_platform "$name" "$candidate" || continue
		DEP_NAMES+=("$name")
		DEP_RANGES+=("$range")
	done <<<"$entries"
}

# Walk the published dependency graph breadth-first and pin every runtime
# package that Pi does not supply itself. Returns the path of a JSON file
# mapping npm name -> { kind, range, version, srcHash }.
resolve_deps() {
	local package="$1" version="$2"
	local registry_name deps_json manifest name range resolved previous tarball hash index=0
	local -A seen=()
	local -a DEP_NAMES=() DEP_RANGES=()

	init_target_platform
	registry_name="$(jq -er --arg package "$package" '.[$package].package' <<<"$SOURCES_JSON")"
	mkdir -p "${RUNTIME_DIR}/deps"
	deps_json="${RUNTIME_DIR}/deps/${package}.json"
	echo '{}' >"$deps_json"

	manifest="$(npm_manifest "${registry_name}@${version}")" ||
		die "Could not read npm metadata for ${registry_name}@${version}"
	enqueue_dependencies "$manifest"
	enqueue_optional_dependencies "$manifest"

	while ((index < ${#DEP_NAMES[@]})); do
		name="${DEP_NAMES[index]}"
		range="${DEP_RANGES[index]}"
		index=$((index + 1))

		resolved="$(resolve_range_version "$name" "$range" 2>/dev/null || true)"
		previous="${seen[$name]:-}"
		if [[ -n "$previous" ]]; then
			if [[ -n "$resolved" && "$resolved" != "$previous" ]]; then
				die "${package}: ${name} resolves to both ${previous} and ${resolved} (${range}); a flat node_modules cannot hold both"
			fi
			continue
		fi
		[[ -n "$resolved" ]] ||
			die "No published ${name} satisfies ${range} (required by ${package})"
		seen[$name]="$resolved"

		manifest="$(npm_manifest "${name}@${resolved}")" || die "Could not read npm metadata for ${name}@${resolved}"
		tarball="$(jq -er '.dist.tarball | select(type == "string" and length > 0)' <<<"$manifest")" || die "Missing tarball for ${name}@${resolved}"
		hash="$(prefetch_unpack_hash "$tarball")" || die "Could not hash ${name}@${resolved}"
		[[ -n "$hash" ]] || die "Empty hash for ${name}@${resolved}"
		jq --arg name "$name" --arg range "$range" --arg version "$resolved" --arg srcHash "$hash" \
			'.[$name] = {kind: "npm-dep", range: $range, version: $version, srcHash: $srcHash}' \
			"$deps_json" >"${deps_json}.next" || die "Could not record ${name}"
		mv "${deps_json}.next" "$deps_json"

		enqueue_dependencies "$manifest"
		enqueue_optional_dependencies "$manifest"
	done

	echo "$deps_json"
}

set_deps_record() {
	local package="$1"
	local deps_file="$2"
	local next_file

	next_file="${STAGING_DIR}/sources.next.json"
	jq --sort-keys \
		--arg package "$package" \
		--slurpfile deps "$deps_file" \
		'.[$package].deps = ($deps[0] | to_entries | sort_by(.key) | from_entries)' \
		"$WORKING_SOURCES" >"$next_file"
	mv "$next_file" "$WORKING_SOURCES"
	write_staged_sources
}

update_package() {
	local package="$1"
	local metadata current version rev="" src_hash="" release_hash="" npm_deps_hash=""
	local owner repo tarball deps_file

	metadata="$(resolve_metadata "$package")"
	current="$(current_version "$package")"
	version="$(jq -er '.version' <<<"$metadata")"
	if ((!FORCE)) && [[ "$current" == "$version" ]]; then
		echo "${package} already at ${current}; skipping."
		return
	fi

	if jq -e --arg package "$package" '.[$package] | has("rev")' <<<"$SOURCES_JSON" >/dev/null; then
		rev="$(jq -er '.gitHead' <<<"$metadata")"
		read -r owner repo <<<"$(github_repo "$package")"
		src_hash="$(prefetch_unpack_hash "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz")"
	elif jq -e --arg package "$package" '.[$package] | has("srcHash")' <<<"$SOURCES_JSON" >/dev/null; then
		tarball="$(jq -er '.dist.tarball' <<<"$metadata")"
		src_hash="$(prefetch_unpack_hash "$tarball")"
	fi
	if jq -e --arg package "$package" '.[$package] | has("releaseHash")' <<<"$SOURCES_JSON" >/dev/null; then
		read -r owner repo <<<"$(github_repo "$package")"
		release_hash="$(prefetch_unpack_hash "https://github.com/${owner}/${repo}/archive/refs/tags/v${version}.tar.gz")"
	fi

	set_source_record "$package" "$version" "$rev" "$src_hash" "$release_hash" "$npm_deps_hash"
	if jq -e --arg package "$package" '.[$package] | has("npmDepsHash")' <<<"$SOURCES_JSON" >/dev/null; then
		compute_npm_deps_hash "$package"
	fi
	if [[ "$(deps_resolver "$package")" == "registry" ]]; then
		deps_file="$(resolve_deps "$package" "$version")"
		set_deps_record "$package" "$deps_file"
	fi
	build_package "$package"
	CHANGED=1
	print_update_line "${package}: ${current} -> ${version}"
}

init_staging() {
	STAGING_DIR="${RUNTIME_DIR}/suite"
	mkdir -p "$STAGING_DIR"
	cp -R "${PI_DIR}/." "$STAGING_DIR"
	WORKING_SOURCES="${STAGING_DIR}/sources.eval"
	printf '%s\n' "$SOURCES_JSON" >"$WORKING_SOURCES"
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
	mv "${STAGING_DIR}/sources.nix" "$SOURCES_FILE"
}

ensure_runtime_shell() {
	local runtime_shell_flag="${UPDATE_PI_IN_NIX_SHELL:-0}"
	local script_path flake_path
	local -a runtime_packages=(
		nixpkgs#bash
		nixpkgs#alejandra
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

	shopt -s inherit_errexit
	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	SOURCES_JSON="$(nix eval --json --file "$SOURCES_FILE")"
	mapfile -t ALL_PACKAGES < <(jq -r 'keys[]' <<<"$SOURCES_JSON")
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
