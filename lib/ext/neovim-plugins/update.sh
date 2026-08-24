#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat <<EOF
Usage: lib/ext/neovim-plugins/update.sh [--plugin NAME] [--force] [--report] [--ansi|--color=WHEN]

Updates every entry in sources.nix by default. Use --plugin with a sources.nix
attribute name to update one plugin.
EOF
}

die() {
	echo "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../../.." && pwd -P)"
	SOURCES_FILE="${REPO_ROOT}/lib/ext/neovim-plugins/sources.nix"
	REQUESTED_PLUGIN=""
	FORCE=0
	REPORT=0
	COLOR_MODE="auto"
	CHANGED=0
	PLUGIN_NAMES=()
	declare -gA PNAMES OWNERS REPOS REFS DATES REVS HASHES
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--plugin | -p)
			[[ $# -ge 2 ]] || die "Missing value for $1"
			REQUESTED_PLUGIN="$2"
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

contains_plugin() {
	local candidate="$1"
	local plugin

	for plugin in "${PLUGIN_NAMES[@]}"; do
		[[ "$plugin" == "$candidate" ]] && return 0
	done
	return 1
}

validate_options() {
	case "$COLOR_MODE" in
	auto | always | never) ;;
	*) die "--color must be one of: auto, always, never" ;;
	esac

	if [[ -n "$REQUESTED_PLUGIN" ]] && ! contains_plugin "$REQUESTED_PLUGIN"; then
		die "Unknown plugin: $REQUESTED_PLUGIN"
	fi
}

use_color() {
	case "$COLOR_MODE" in
	always) return 0 ;;
	never) return 1 ;;
	auto) [[ -t 1 ]] ;;
	*) return 1 ;;
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

load_sources() {
	local sources_json plugin

	[[ -f "$SOURCES_FILE" ]] || die "Sources file not found: $SOURCES_FILE"
	sources_json="$(nix eval --json --file "$SOURCES_FILE")"
	mapfile -t PLUGIN_NAMES < <(jq -er 'keys[]' <<<"$sources_json")
	((${#PLUGIN_NAMES[@]} > 0)) || die "No plugins declared in $SOURCES_FILE"

	for plugin in "${PLUGIN_NAMES[@]}"; do
		PNAMES[$plugin]="$(jq -er --arg plugin "$plugin" '.[$plugin].pname' <<<"$sources_json")"
		OWNERS[$plugin]="$(jq -er --arg plugin "$plugin" '.[$plugin].owner' <<<"$sources_json")"
		REPOS[$plugin]="$(jq -er --arg plugin "$plugin" '.[$plugin].repo' <<<"$sources_json")"
		REFS[$plugin]="$(jq -er --arg plugin "$plugin" '.[$plugin].ref' <<<"$sources_json")"
		DATES[$plugin]="$(jq -er --arg plugin "$plugin" '.[$plugin].date' <<<"$sources_json")"
		REVS[$plugin]="$(jq -er --arg plugin "$plugin" '.[$plugin].rev' <<<"$sources_json")"
		HASHES[$plugin]="$(jq -er --arg plugin "$plugin" '.[$plugin].hash' <<<"$sources_json")"
	done
}

github_commit() {
	local plugin="$1"
	local url="https://api.github.com/repos/${OWNERS[$plugin]}/${REPOS[$plugin]}/commits/${REFS[$plugin]}"
	local -a curl_args=(
		-fsSL
		-H "Accept: application/vnd.github+json"
		-H "X-GitHub-Api-Version: 2022-11-28"
	)

	if [[ -n "${GITHUB_TOKEN:-}" ]]; then
		curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
	fi

	curl "${curl_args[@]}" "$url"
}

prefetch_plugin() {
	local plugin="$1"
	local rev="$2"
	local url="https://github.com/${OWNERS[$plugin]}/${REPOS[$plugin]}/archive/${rev}.tar.gz"

	nix store prefetch-file --json --hash-type sha256 --unpack "$url" | jq -er '.hash'
}

update_plugin() {
	local plugin="$1"
	local metadata latest_rev latest_date current_version latest_version latest_hash

	metadata="$(github_commit "$plugin")"
	latest_rev="$(jq -er '.sha' <<<"$metadata")"
	latest_date="$(jq -er '.commit.committer.date[0:10]' <<<"$metadata")"
	current_version="0-unstable-${DATES[$plugin]} (${REVS[$plugin]:0:12})"
	latest_version="0-unstable-${latest_date} (${latest_rev:0:12})"

	if ((REPORT)); then
		if [[ "${REVS[$plugin]}" == "$latest_rev" && "${DATES[$plugin]}" == "$latest_date" ]]; then
			echo "- neovim/${plugin}: ${current_version} [latest]"
		else
			print_update_line "neovim/${plugin}: ${current_version} -> ${latest_version}"
		fi
		return
	fi

	if [[ "${REVS[$plugin]}" == "$latest_rev" && "${DATES[$plugin]}" == "$latest_date" ]] && ((!FORCE)); then
		echo "${plugin} already at ${latest_version}; skipping prefetch."
		return
	fi
	if [[ "${REVS[$plugin]}" == "$latest_rev" ]] && ((!FORCE)); then
		DATES[$plugin]="$latest_date"
		CHANGED=1
		echo "Updated ${plugin} metadata"
		echo "  version=0-unstable-${latest_date}"
		echo "  rev=${latest_rev}"
		return
	fi

	latest_hash="$(prefetch_plugin "$plugin" "$latest_rev")"
	DATES[$plugin]="$latest_date"
	REVS[$plugin]="$latest_rev"
	HASHES[$plugin]="$latest_hash"
	CHANGED=1

	echo "Updated ${plugin}"
	echo "  version=0-unstable-${latest_date}"
	echo "  rev=${latest_rev}"
	echo "  hash=${latest_hash}"
}

render_sources() {
	local plugin

	echo "{"
	for plugin in "${PLUGIN_NAMES[@]}"; do
		cat <<EOF
  ${plugin} = {
    pname = "${PNAMES[$plugin]}";
    owner = "${OWNERS[$plugin]}";
    repo = "${REPOS[$plugin]}";
    ref = "${REFS[$plugin]}";
    date = "${DATES[$plugin]}";
    rev = "${REVS[$plugin]}";
    hash = "${HASHES[$plugin]}";
  };

EOF
	done
	echo "}"
}

write_sources() {
	local tmp_file

	mkdir -p "${REPO_ROOT}/tmp"
	tmp_file="$(mktemp "${REPO_ROOT}/tmp/update-neovim-plugins.XXXXXX.nix")"
	trap 'rm -f "${tmp_file:-}"' RETURN
	render_sources >"$tmp_file"
	alejandra "$tmp_file" >/dev/null
	mv "$tmp_file" "$SOURCES_FILE"
	trap - RETURN
}

ensure_runtime_shell() {
	local runtime_shell_flag="${UPDATE_NEOVIM_PLUGINS_IN_NIX_SHELL:-0}"
	local script_path flake_path
	local -a runtime_packages=(
		nixpkgs#alejandra
		nixpkgs#coreutils
		nixpkgs#curl
		nixpkgs#jq
	)

	if [[ "$runtime_shell_flag" == "1" ]]; then
		return
	fi

	command -v nix >/dev/null 2>&1 || die "Required command not found: nix"
	script_path="${BASH_SOURCE[0]:-$0}"
	flake_path="$(cd "$(dirname "$script_path")/../../.." && pwd -P)"
	exec nix --quiet --no-warn-dirty shell --inputs-from "$flake_path" "${runtime_packages[@]}" -c env UPDATE_NEOVIM_PLUGINS_IN_NIX_SHELL=1 bash "$script_path" "$@"
}

main() {
	local plugin

	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	load_sources
	validate_options

	for plugin in "${PLUGIN_NAMES[@]}"; do
		[[ -n "$REQUESTED_PLUGIN" && "$plugin" != "$REQUESTED_PLUGIN" ]] && continue
		update_plugin "$plugin"
	done

	if ((CHANGED)); then
		write_sources
	fi
}

main "$@"
