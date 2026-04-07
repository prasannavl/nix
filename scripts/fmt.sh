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
	local flake_dir="$1"
	local project_name

	if [ "${#PROJECT_NAMES[@]}" -eq 0 ]; then
		return 0
	fi

	for project_name in "${PROJECT_NAMES[@]}"; do
		if [ "$(basename "${flake_dir}")" = "${project_name}" ]; then
			return 0
		fi
	done

	return 1
}

run_optional_flake_app() {
	local installable="$1"
	local output=""
	local status=0

	if output="$(nix run "${installable}" 2>&1)"; then
		if [ -n "${output}" ]; then
			printf '%s\n' "${output}" >&2
		fi
		return 0
	fi
	status=$?

	if printf '%s\n' "${output}" | grep -Eq \
		'does not provide attribute|attribute .* missing|flake .* does not provide'; then
		return 0
	fi

	if [ -n "${output}" ]; then
		printf '%s\n' "${output}" >&2
	fi
	return "${status}"
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

collect_selected_flake_dirs() {
	local flake_nix=""
	local flake_dir=""

	while IFS= read -r -d '' flake_nix; do
		flake_dir="$(dirname "${flake_nix}")"
		if matches_selected_project "${flake_dir}"; then
			printf '%s\0' "${flake_dir}"
		fi
	done < <(find pkgs -name flake.nix -print0 | sort -z)
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
	local -a flake_dirs=()
	local flake_dir=""

	mapfile -d $'\0' -t flake_dirs < <(collect_selected_flake_dirs)

	if [ "${#flake_dirs[@]}" -eq 0 ]; then
		return
	fi

	printf '[fmt] Formatting package-managed files\n' >&2
	for flake_dir in "${flake_dirs[@]}"; do
		printf '  - %s\n' "${flake_dir}" >&2
		run_optional_flake_app "./${flake_dir}#fmt"
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
