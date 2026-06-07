_repo_bash_completions_source_dir() {
	local source_path="${BASH_SOURCE[0]}"

	cd "$(dirname "$source_path")/.." && pwd -P
}

_repo_bash_completions_source_load() {
	local repo_root
	local loader

	if ! type complete >/dev/null 2>&1 || ! type compgen >/dev/null 2>&1; then
		return 0
	fi

	repo_root="$(_repo_bash_completions_source_dir)"
	loader="${repo_root}/pkgs/support/bash-completions/load.bash"

	if [ -f "$loader" ]; then
		# shellcheck source=/dev/null
		source "$loader"
	fi
}

_repo_bash_completions_source_load
