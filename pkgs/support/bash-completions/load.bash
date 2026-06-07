_repo_bash_completion_dir() {
	local source_path="${BASH_SOURCE[0]}"

	cd "$(dirname "$source_path")" && pwd -P
}

_repo_bash_completion_source() {
	local completions_dir="$1"
	local script_name="$2"
	local script_path="${completions_dir}/${script_name}"

	if [ -f "$script_path" ]; then
		# shellcheck source=/dev/null
		source "$script_path"
	fi
}

_repo_bash_completion_load() {
	local completions_dir

	completions_dir="$(_repo_bash_completion_dir)"
	_repo_bash_completion_source "$completions_dir" nix-run-apps.bash
	_repo_bash_completion_source "$completions_dir" age-secrets.bash
}

_repo_bash_completion_load
