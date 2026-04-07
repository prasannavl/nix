#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	cat >&2 <<'EOF'
Usage:
  lint deps
  lint check-deps
  lint [MODE] [fix] [--base <ref>] [--project <name>]

Actions:
  deps        Verify the lint runtime is available.
  check-deps  Verify the lint runtime commands are available on PATH.
  fix         Apply best-effort auto-fixes, then re-run lint.

Modes:
  (default)       Auto: diff lints against origin/master, full flake checks
                  on changed sub-projects only.
  --diff          Diff against --base REF (required with --diff).
  --full-no-test  Full lints on all files, flake checks on all sub-projects
                  but skip test checks.
  --full          Full lints on all files, full flake checks on all
                  sub-projects including tests.

Options:
  --base REF  Compare against REF (required with --diff, optional with auto
              to override origin/master).
  --project NAME
  -h, --help
EOF
}

die() {
	printf '%s\n' "$*" >&2
	exit 1
}

init_vars() {
	REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"
	LINT_MODE='auto'
	LINT_FIX='0'
	LINT_DIFF_BASE=''
	PROJECT_NAMES=()
	CURRENT_STEP=""
	CURRENT_STEP_DESCRIPTION=""
	readonly -a LINT_RUNTIME_COMMANDS=(
		git
		jq
		nix
		treefmt
		alejandra
		deno
		tofu
		shfmt
		statix
		deadnix
		shellcheck
		actionlint
		markdownlint-cli2
		tflint
		find
		sort
	)
}

ensure_runtime_shell() {
	local runtime_shell_flag="${LINT_IN_NIX_SHELL:-0}"
	local script_path
	local flake_path
	local -a runtime_packages=(
		nixpkgs#git
		nixpkgs#jq
		nixpkgs#nix
		nixpkgs#treefmt
		nixpkgs#alejandra
		nixpkgs#deno
		nixpkgs#opentofu
		nixpkgs#shfmt
		nixpkgs#statix
		nixpkgs#deadnix
		nixpkgs#shellcheck
		nixpkgs#actionlint
		nixpkgs#markdownlint-cli2
		nixpkgs#tflint
		nixpkgs#findutils
		nixpkgs#coreutils
	)

	if [ "$runtime_shell_flag" = "1" ]; then
		return
	fi

	if ! command -v nix >/dev/null 2>&1; then
		die "Required command not found: nix"
	fi

	script_path="${BASH_SOURCE[0]:-$0}"
	flake_path="$(cd "$(dirname "${script_path}")/.." && pwd -P)"
	exec nix shell --inputs-from "${flake_path}" "${runtime_packages[@]}" -c env LINT_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

require_cmds() {
	local cmd=""

	for cmd in "$@"; do
		command -v "${cmd}" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
	done
}

report_exit() {
	local exit_code="$1"

	if [ "${exit_code}" -ne 0 ]; then
		if [ -n "${CURRENT_STEP}" ]; then
			printf '\n[lint] FAILED at %s: %s\n' "${CURRENT_STEP}" "${CURRENT_STEP_DESCRIPTION}" >&2
		else
			printf '\n[lint] FAILED before a lint step completed\n' >&2
		fi
	fi
}

log_step() {
	printf '\n[%s] %s\n' "$1" "$2" >&2
}

run_step() {
	CURRENT_STEP="$1"
	CURRENT_STEP_DESCRIPTION="$2"
	shift 2

	log_step "${CURRENT_STEP}" "${CURRENT_STEP_DESCRIPTION}"
	"$@"
}

ensure_runtime_tools() {
	require_cmds "${LINT_RUNTIME_COMMANDS[@]}"
}

run_deps_action() {
	ensure_runtime_tools
}

run_check_deps_action() {
	ensure_runtime_tools
}

action_help_requested() {
	local -a args=("$@")

	[ "${#args[@]}" -gt 0 ] && { [ "${args[0]}" = "-h" ] || [ "${args[0]}" = "--help" ]; }
}

require_no_extra_action_args() {
	local action_name="$1"
	shift

	[ "$#" -eq 0 ] || die "${action_name} does not accept additional arguments"
}

parse_lint_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		fix)
			if [ "${LINT_FIX}" = 1 ]; then
				die "lint: duplicate action: $1"
			fi
			LINT_FIX='1'
			;;
		--diff)
			LINT_MODE='diff'
			;;
		--full-no-test)
			LINT_MODE='full-no-test'
			;;
		--full)
			LINT_MODE='full'
			;;
		--base)
			shift
			[ "$#" -gt 0 ] || die "lint: --base requires an argument"
			LINT_DIFF_BASE="$1"
			;;
		--project)
			shift
			[ "$#" -gt 0 ] || die "lint: --project requires an argument"
			PROJECT_NAMES+=("$1")
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			usage
			die "lint: unknown argument: $1"
			;;
		esac
		shift
	done

	if [ "${LINT_MODE}" = diff ] && [ -z "${LINT_DIFF_BASE}" ]; then
		die "lint: --diff requires --base <ref>"
	fi

	if [ "${LINT_MODE}" = auto ] && [ -z "${LINT_DIFF_BASE}" ]; then
		LINT_DIFF_BASE='origin/master'
	fi
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

collect_diff_files() {
	local -a patterns=("$@")
	local -A seen=()

	if [ -n "${LINT_DIFF_BASE}" ]; then
		emit_unique_existing_from seen git diff --name-only -z --diff-filter=ACMR "${LINT_DIFF_BASE}" HEAD -- "${patterns[@]}"
		return
	fi

	emit_unique_existing_from seen git diff --name-only -z --cached --diff-filter=ACMR -- "${patterns[@]}"
	emit_unique_existing_from seen git diff --name-only -z --diff-filter=ACMR -- "${patterns[@]}"
	emit_unique_existing_from seen git ls-files -z --others --exclude-standard -- "${patterns[@]}"

	if [ "${#seen[@]}" -eq 0 ] && git rev-parse --verify HEAD^ >/dev/null 2>&1; then
		emit_unique_existing_from seen git diff --name-only -z --diff-filter=ACMR HEAD^ HEAD -- "${patterns[@]}"
	fi
}

collect_repo_files() {
	local -a patterns=("$@")
	local -A seen=()

	emit_unique_existing_from seen git ls-files -z --cached --others --exclude-standard -- "${patterns[@]}"
}

collect_root_only_files_from() {
	local path=""

	while IFS= read -r -d $'\0' path; do
		case "${path}" in
		pkgs/*) ;;
		*)
			printf '%s\0' "${path}"
			;;
		esac
	done
}

lint_scope() {
	case "${LINT_MODE}" in
	auto | diff) echo diff ;;
	*) echo full ;;
	esac
}

collect_files() {
	if [ "$(lint_scope)" = diff ]; then
		collect_diff_files "$@"
	else
		collect_repo_files "$@"
	fi
}

collect_root_files() {
	collect_files "$@" | collect_root_only_files_from
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

collect_changed_flake_dirs() {
	local -a all_changed=()
	local flake_dir changed

	mapfile -d $'\0' -t all_changed < <(collect_files '*')

	while IFS= read -r -d '' flake_dir; do
		flake_dir="$(dirname "${flake_dir}")"
		if ! matches_selected_project "${flake_dir}"; then
			continue
		fi
		for changed in "${all_changed[@]}"; do
			if [[ "${changed}" = "${flake_dir}/"* ]]; then
				printf '%s\0' "${flake_dir}"
				break
			fi
		done
	done < <(find pkgs -name flake.nix -print0 | sort -z)
}

collect_all_flake_dirs() {
	find pkgs -name flake.nix -print0 | sort -z |
		while IFS= read -r -d '' flake_nix; do
			local flake_dir
			flake_dir="$(dirname "${flake_nix}")"
			if matches_selected_project "${flake_dir}"; then
				printf '%s\0' "${flake_dir}"
			fi
		done
}

detect_nix_system() {
	nix eval --raw --impure --expr 'builtins.currentSystem'
}

project_arg_list() {
	local project_name=""

	for project_name in "${PROJECT_NAMES[@]}"; do
		printf '%s\0' "--project"
		printf '%s\0' "${project_name}"
	done
}

run_conventional_flake_checks() {
	local flake_dir="$1"
	local nix_system="$2"
	local include_test="$3"
	local -a checks=()

	mapfile -t checks < <(
		nix eval --json "./${flake_dir}#checks.${nix_system}" 2>/dev/null |
			jq -r --argjson include_test "${include_test}" '
				keys[]
				| select(. == "fmt" or . == "lint" or (. == "test" and $include_test))
			'
	)

	if [ "${#checks[@]}" -eq 0 ]; then
		return
	fi

	local check
	for check in "${checks[@]}"; do
		printf '    check: %s\n' "${check}" >&2
		nix build "./${flake_dir}#checks.${nix_system}.${check}" --no-link
	done
}

run_conventional_flake_apps() {
	local flake_dir="$1"
	local nix_system="$2"
	shift
	shift
	local app=""
	local -a app_names=("$@")
	local output=""
	local status=0

	for app in "${app_names[@]}"; do
		if output="$(nix run "./${flake_dir}#${app}" 2>&1)"; then
			printf '    app: %s\n' "${app}" >&2
			if [ -n "${output}" ]; then
				printf '%s\n' "${output}" >&2
			fi
			continue
		fi
		status=$?

		if printf '%s\n' "${output}" | grep -Eq \
			'does not provide attribute|attribute .* missing|flake .* does not provide'; then
			continue
		fi

		printf '    app: %s\n' "${app}" >&2
		if [ -n "${output}" ]; then
			printf '%s\n' "${output}" >&2
		fi
		return "${status}"
	done
}

run_lint_action() {
	local nix_file=""
	local -a deno_files=()
	local -a flake_dirs=()
	local -a tf_project_dirs=()
	local local_tf_dir=""
	local nix_system=""

	local scope

	cd "${REPO_ROOT}"
	ensure_runtime_tools
	scope="$(lint_scope)"
	nix_system="$(detect_nix_system)"

	mapfile -d $'\0' -t nix_files < <(collect_root_files '*.nix')
	mapfile -d $'\0' -t shell_files < <(collect_root_files '*.sh' '.githooks/*')
	mapfile -d $'\0' -t deno_files < <(collect_root_files '*.md' '*.json' '*.jsonc')
	mapfile -d $'\0' -t markdown_files < <(collect_root_files '*.md')
	mapfile -d $'\0' -t tf_files < <(collect_root_files '*.tf' '*.tfvars')

	if [ "${#PROJECT_NAMES[@]}" -eq 0 ]; then
		mapfile -d $'\0' -t tf_project_dirs < <(find tf -mindepth 1 -maxdepth 1 -type d -name '*-*' -print0 | sort -z)
	fi

	if [ "${#PROJECT_NAMES[@]}" -gt 0 ]; then
		mapfile -d $'\0' -t flake_dirs < <(collect_all_flake_dirs)
	elif [ "$(lint_scope)" = diff ]; then
		mapfile -d $'\0' -t flake_dirs < <(collect_changed_flake_dirs)
	else
		mapfile -d $'\0' -t flake_dirs < <(collect_all_flake_dirs)
	fi

	if [ "${LINT_FIX}" = 1 ]; then
		printf '[lint-fix] Applying automatic fixes (%s)\n' "${scope}" >&2

		local -a fmt_args=()
		mapfile -d $'\0' -t fmt_args < <(project_arg_list)

		run_step fmt-fix 'Formatting root-managed files and package formatters' bash "${REPO_ROOT}/scripts/fmt.sh" "${fmt_args[@]}"

		if [ "${#flake_dirs[@]}" -gt 0 ]; then
			CURRENT_STEP=package-lint-fix
			CURRENT_STEP_DESCRIPTION="Applying package-local lint fixes"
			log_step "${CURRENT_STEP}" "${CURRENT_STEP_DESCRIPTION}"
			local flake_dir=""
			for flake_dir in "${flake_dirs[@]}"; do
				printf '  - %s\n' "${flake_dir}" >&2
				run_conventional_flake_apps "${flake_dir}" "${nix_system}" "lint-fix" fmt
			done
		fi

		if [ "${#PROJECT_NAMES[@]}" -eq 0 ]; then
			if [ "${#nix_files[@]}" -gt 0 ]; then
				CURRENT_STEP=statix-fix
				CURRENT_STEP_DESCRIPTION="Fixing ${scope} Nix files"
				log_step "${CURRENT_STEP}" "${CURRENT_STEP_DESCRIPTION}"
				for nix_file in "${nix_files[@]}"; do
					printf '  - %s\n' "${nix_file}" >&2
					statix fix -- "${nix_file}"
				done
			fi

			if [ "${#markdown_files[@]}" -gt 0 ]; then
				run_step markdownlint-fix "Fixing ${scope} Markdown files" markdownlint-cli2 --fix "${markdown_files[@]}"
			fi

			if [ "${#tf_project_dirs[@]}" -gt 0 ]; then
				CURRENT_STEP=tflint-fix
				CURRENT_STEP_DESCRIPTION='Fixing Terraform/OpenTofu projects'
				log_step "${CURRENT_STEP}" "${CURRENT_STEP_DESCRIPTION}"
				for local_tf_dir in "${tf_project_dirs[@]}"; do
					printf '  - %s\n' "${local_tf_dir}" >&2
					tflint --fix --chdir "${local_tf_dir}"
				done
			fi
		fi

		run_step fmt-fix-final 'Re-formatting root-managed files and package formatters' bash "${REPO_ROOT}/scripts/fmt.sh" "${fmt_args[@]}"
		printf '\n[lint-fix] Re-running lint to report remaining issues\n' >&2
	fi

	if [ "${#PROJECT_NAMES[@]}" -eq 0 ]; then
		printf '[lint] Running shared lint suite (%s)\n' "${scope}" >&2

		if [ "${#nix_files[@]}" -gt 0 ]; then
			run_step alejandra-check 'Checking Nix formatting drift' alejandra --check "${nix_files[@]}"
		fi

		if [ "${#deno_files[@]}" -gt 0 ]; then
			run_step deno-fmt-check 'Checking Markdown/JSON formatting drift' deno fmt --check "${deno_files[@]}"
		fi

		if [ "${#tf_files[@]}" -gt 0 ]; then
			run_step tofu-fmt-check 'Checking Terraform/OpenTofu formatting drift' tofu fmt -check -write=false -diff "${tf_files[@]}"
		fi

		if [ "${#shell_files[@]}" -gt 0 ]; then
			run_step shfmt-check 'Checking shell formatting drift' shfmt -d "${shell_files[@]}"
		fi

		if [ "${#nix_files[@]}" -gt 0 ]; then
			CURRENT_STEP=statix
			CURRENT_STEP_DESCRIPTION="Linting ${scope} Nix files"
			log_step "${CURRENT_STEP}" "${CURRENT_STEP_DESCRIPTION}"
			for nix_file in "${nix_files[@]}"; do
				printf '  - %s\n' "${nix_file}" >&2
				statix check -- "${nix_file}"
			done

			CURRENT_STEP=deadnix
			CURRENT_STEP_DESCRIPTION="Checking ${scope} Nix files for unused bindings"
			log_step "${CURRENT_STEP}" "${CURRENT_STEP_DESCRIPTION}"
			for nix_file in "${nix_files[@]}"; do
				printf '  - %s\n' "${nix_file}" >&2
				deadnix -- "${nix_file}"
			done
		fi

		if [ "${#shell_files[@]}" -gt 0 ]; then
			run_step shellcheck "Linting ${scope} shell files" shellcheck --external-sources --shell=bash "${shell_files[@]}"
		fi

		run_step actionlint 'Linting GitHub Actions workflows' actionlint

		if [ "${#markdown_files[@]}" -gt 0 ]; then
			run_step markdownlint "Linting ${scope} Markdown files" markdownlint-cli2 "${markdown_files[@]}"
		fi

		if [ "${#tf_project_dirs[@]}" -gt 0 ]; then
			CURRENT_STEP=tflint
			CURRENT_STEP_DESCRIPTION='Linting Terraform/OpenTofu projects'
			log_step "${CURRENT_STEP}" "${CURRENT_STEP_DESCRIPTION}"
			for local_tf_dir in "${tf_project_dirs[@]}"; do
				printf '  - %s\n' "${local_tf_dir}" >&2
				tflint --chdir "${local_tf_dir}"
			done
		fi

		run_step root-flake-check 'Checking root flake evaluates cleanly' \
			nix flake check --no-build 2> >(grep -v "^warning: unknown flake output\|^warning: The check omitted these incompatible systems" >&2)
	fi

	if [ "${#flake_dirs[@]}" -gt 0 ]; then
		local include_test='true'

		if [ "${LINT_MODE}" = 'full-no-test' ]; then
			include_test='false'
		fi

		CURRENT_STEP=flake-check
		CURRENT_STEP_DESCRIPTION="Running conventional package checks for sub-projects"
		log_step "${CURRENT_STEP}" "${CURRENT_STEP_DESCRIPTION}"
		local flake_dir
		for flake_dir in "${flake_dirs[@]}"; do
			printf '  - %s\n' "${flake_dir}" >&2
			run_conventional_flake_checks "${flake_dir}" "${nix_system}" "${include_test}"
		done
	fi
}

main() {
	local -a request_args=("$@")

	trap 'report_exit "$?"' EXIT
	ensure_runtime_shell "$@"
	init_vars

	if [ "${#request_args[@]}" -eq 0 ]; then
		parse_lint_args
		run_lint_action
		return
	fi

	case "${request_args[0]}" in
	deps)
		if action_help_requested "${request_args[@]:1}"; then
			usage
			return 0
		fi
		require_no_extra_action_args "deps" "${request_args[@]:1}"
		run_deps_action
		return
		;;
	check-deps)
		if action_help_requested "${request_args[@]:1}"; then
			usage
			return 0
		fi
		require_no_extra_action_args "check-deps" "${request_args[@]:1}"
		run_check_deps_action
		return
		;;
	esac

	parse_lint_args "${request_args[@]}"
	run_lint_action
}

main "$@"
