#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat >&2 <<'EOF'
Usage:
  fmt [--project <name>]
EOF
}

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
	PROJECT_NAMES=()
}

ensure_runtime_shell() {
	local runtime_shell_flag="${FMT_IN_NIX_SHELL:-0}"
	local script_path
	local flake_path
	local -a runtime_packages=(
		nixpkgs#bash
		nixpkgs#findutils
		nixpkgs#git
		nixpkgs#jq
		nixpkgs#nix
		nixpkgs#treefmt
		nixpkgs#alejandra
		nixpkgs#deno
		nixpkgs#opentofu
		nixpkgs#shfmt
	)

	if [ "$runtime_shell_flag" = "1" ]; then
		return
	fi

	if ! command -v nix >/dev/null 2>&1; then
		die "Required command not found: nix"
	fi

	script_path="${BASH_SOURCE[0]:-$0}"
	flake_path="$(cd "$(dirname "${script_path}")/.." && pwd -P)"
	exec nix shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env FMT_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--project)
			shift
			[ "$#" -gt 0 ] || die "fmt: --project requires an argument"
			PROJECT_NAMES+=("$1")
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			usage
			die "fmt: unknown argument: $1"
			;;
		esac
		shift
	done
}

matches_selected_project() {
	local project_path="$1"
	local project_name

	if [ "${#PROJECT_NAMES[@]}" -eq 0 ]; then
		return 0
	fi

	for project_name in "${PROJECT_NAMES[@]}"; do
		if [ "$(basename "${project_path}")" = "${project_name}" ]; then
			return 0
		fi
	done

	return 1
}

emit_unique_existing_from() {
	local -n seen_ref="$1"
	shift
	local -a cmd=("$@")
	local path=""

	while IFS= read -r -d $'\0' path; do
		[ -n "${path}" ] || continue
		[ -e "${path}" ] || continue
		if ! [[ -v "seen_ref[${path}]" ]]; then
			printf '%s\0' "${path}"
			seen_ref["${path}"]=1
		fi
	done < <("${cmd[@]}" 2>/dev/null || true)
}

collect_root_files() {
	local -a patterns=("$@")
	local -A seen=()
	local path=""

	while IFS= read -r -d $'\0' path; do
		case "${path}" in
		pkgs/*) ;;
		*)
			if ! [[ -v "seen[${path}]" ]]; then
				printf '%s\0' "${path}"
				seen["${path}"]=1
			fi
			;;
		esac
	done < <(emit_unique_existing_from seen git ls-files -z --cached --others --exclude-standard -- "${patterns[@]}")
}

manifest_package_records() {
	[ -n "${PKG_OPS_MANIFEST:-}" ] || return 0
	[ -f "${PKG_OPS_MANIFEST}" ] || return 0
	jq -c '.packages[]' "${PKG_OPS_MANIFEST}"
}

run_manifest_command() {
	local project_path="$1"
	local env_script="$2"
	local command="$3"

	(
		cd "${REPO_ROOT}/${project_path}"
		export repo_root="${REPO_ROOT}"
		set --
		if [ -n "${env_script}" ]; then
			eval "${env_script}"
		fi
		eval "${command}"
	)
}

run_root_treefmt() {
	local -a root_files=()

	if [ "${#PROJECT_NAMES[@]}" -gt 0 ]; then
		return
	fi

	mapfile -d $'\0' -t root_files < <(
		collect_root_files \
			'*.nix' \
			'*.md' \
			'*.json' \
			'*.jsonc' \
			'*.tf' \
			'*.tfvars' \
			'*.sh' \
			'.githooks/*'
	)

	if [ "${#root_files[@]}" -eq 0 ]; then
		return
	fi

	printf '[fmt] Formatting root-managed files\n' >&2
	treefmt "${root_files[@]}"
}

run_child_fmts() {
	local -a package_records=()
	local record=""
	local project_path=""
	local env_script=""
	local command=""

	mapfile -t package_records < <(manifest_package_records)

	if [ "${#package_records[@]}" -eq 0 ]; then
		return
	fi

	printf '[fmt] Formatting package-managed files\n' >&2
	for record in "${package_records[@]}"; do
		project_path="$(jq -r '.path' <<<"${record}")"
		if ! matches_selected_project "${project_path}"; then
			continue
		fi
		command="$(jq -r '.apps.fmt.command // empty' <<<"${record}")"
		if [ -z "${command}" ]; then
			continue
		fi
		env_script="$(jq -r '.apps.fmt.envScript // ""' <<<"${record}")"
		printf '  - %s\n' "${project_path}" >&2
		run_manifest_command "${project_path}" "${env_script}" "${command}"
	done
}

main() {
	ensure_runtime_shell "$@"
	init_vars
	parse_args "$@"
	cd "${REPO_ROOT}"
	run_root_treefmt
	run_child_fmts
}

main "$@"
