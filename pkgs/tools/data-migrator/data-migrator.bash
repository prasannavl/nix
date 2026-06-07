_data_migrator_repo_root() {
	local root

	root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
	printf '%s\n' "$root"
}

_data_migrator_profiles() {
	local root profiles_file

	if [ -n "${DATA_MIGRATOR_CONFIG_DIR:-}" ] && [ -d "$DATA_MIGRATOR_CONFIG_DIR" ]; then
		find "$DATA_MIGRATOR_CONFIG_DIR" -maxdepth 1 -type f -name '*.yaml' \
			-printf '%f\n' 2>/dev/null | sed 's/[.]yaml$//'
		return 0
	fi

	root="$(_data_migrator_repo_root)" || return 0
	profiles_file="${root}/pkgs/tools/data-migrator/profiles.nix"
	nix eval --json --file "$profiles_file" 2>/dev/null |
		jq -r 'keys[]' 2>/dev/null
}

_data_migrator_hosts() {
	local root config

	root="$(_data_migrator_repo_root)" || return 0
	config="${root}/hosts/nixbot.nix"
	nix eval --json --file "$config" 2>/dev/null |
		jq -r '(.hosts // {}) | keys[]' 2>/dev/null
}

_data_migrator_compgen_words() {
	local cur="$1"
	local words="$2"
	local prefix="${3:-}"

	if [ -n "$prefix" ]; then
		mapfile -t COMPREPLY < <(compgen -P "$prefix" -W "$words" -- "$cur")
	else
		mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
	fi
}

_data_migrator_compgen_files() {
	local cur="$1"
	local prefix="${2:-}"

	mapfile -t COMPREPLY < <(compgen -f -- "$cur")
	if [ -n "$prefix" ]; then
		COMPREPLY=("${COMPREPLY[@]/#/${prefix}}")
	fi
}

_data_migrator() {
	local cur prev eq_opt
	local -a options

	COMPREPLY=()
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD - 1]}"
	eq_opt=""
	if [ "$prev" = "=" ] && [ "$COMP_CWORD" -ge 2 ]; then
		eq_opt="${COMP_WORDS[COMP_CWORD - 2]}"
	elif [[ "$cur" == =* ]]; then
		eq_opt="$prev"
		cur="${cur#=}"
	fi

	options=(
		--profile --config --source-host --target-host --target-dir
		--source-base --target-base --transport --copy-mode --warm
		--source-drain-host --target-drain-host --skip-source-drain
		--no-resume-target --resume-source --skip-deploy --nixbot-goal
		--nixbot-dry --repo-root --rsync-ssh --source-rsync-path
		--remote-sudo --no-remote-sudo --local-sudo --no-local-sudo
		--incus-instance --source-instance --target-instance
		--source-project --target-project --incus-controller-host
		--incus-remote --target-incus-remote --target-storage-pool
		--incus-migration-mode --incus-copy-mode --incus-stop-timeout
		--snapshot-prefix --incus-stateless --no-incus-stateless
		--incus-allow-inconsistent --no-incus-allow-inconsistent
		--force-refresh-existing --leave-source-running --no-start-target
		--dry-run --keep-workdir --help
	)

	case "$prev" in
	--profile)
		_data_migrator_compgen_words "$cur" "$(_data_migrator_profiles)"
		return 0
		;;
	--source-host | --target-host | --source-drain-host | --target-drain-host | --incus-controller-host)
		_data_migrator_compgen_words "$cur" "$(_data_migrator_hosts)"
		return 0
		;;
	--incus-instance | --source-instance | --target-instance)
		_data_migrator_compgen_words "$cur" "$(_data_migrator_profiles) $(_data_migrator_hosts)"
		return 0
		;;
	--transport)
		_data_migrator_compgen_words "$cur" "auto rsync tar"
		return 0
		;;
	--copy-mode)
		_data_migrator_compgen_words "$cur" "pull push"
		return 0
		;;
	--nixbot-goal)
		_data_migrator_compgen_words "$cur" "switch boot test dry-activate"
		return 0
		;;
	--incus-migration-mode)
		_data_migrator_compgen_words "$cur" "auto incus-native files"
		return 0
		;;
	--incus-copy-mode)
		_data_migrator_compgen_words "$cur" "pull push relay"
		return 0
		;;
	--config | --target-dir | --repo-root | --source-rsync-path)
		_data_migrator_compgen_files "$cur"
		return 0
		;;
	esac

	case "$eq_opt" in
	--profile)
		_data_migrator_compgen_words "$cur" "$(_data_migrator_profiles)"
		return 0
		;;
	--source-host | --target-host | --source-drain-host | --target-drain-host | --incus-controller-host)
		_data_migrator_compgen_words "$cur" "$(_data_migrator_hosts)"
		return 0
		;;
	--incus-instance | --source-instance | --target-instance)
		_data_migrator_compgen_words "$cur" "$(_data_migrator_profiles) $(_data_migrator_hosts)"
		return 0
		;;
	--transport)
		_data_migrator_compgen_words "$cur" "auto rsync tar"
		return 0
		;;
	--copy-mode)
		_data_migrator_compgen_words "$cur" "pull push"
		return 0
		;;
	--nixbot-goal)
		_data_migrator_compgen_words "$cur" "switch boot test dry-activate"
		return 0
		;;
	--incus-migration-mode)
		_data_migrator_compgen_words "$cur" "auto incus-native files"
		return 0
		;;
	--incus-copy-mode)
		_data_migrator_compgen_words "$cur" "pull push relay"
		return 0
		;;
	--config | --target-dir | --repo-root | --source-rsync-path)
		_data_migrator_compgen_files "$cur"
		return 0
		;;
	esac

	case "$cur" in
	--profile=*)
		_data_migrator_compgen_words "${cur#--profile=}" "$(_data_migrator_profiles)" "--profile="
		;;
	--source-host=* | --target-host=* | --source-drain-host=* | --target-drain-host=* | --incus-controller-host=*)
		_data_migrator_compgen_words "${cur#*=}" "$(_data_migrator_hosts)" "${cur%%=*}="
		;;
	--transport=*)
		_data_migrator_compgen_words "${cur#--transport=}" "auto rsync tar" "--transport="
		;;
	--copy-mode=*)
		_data_migrator_compgen_words "${cur#--copy-mode=}" "pull push" "--copy-mode="
		;;
	--nixbot-goal=*)
		_data_migrator_compgen_words "${cur#--nixbot-goal=}" "switch boot test dry-activate" "--nixbot-goal="
		;;
	--incus-migration-mode=*)
		_data_migrator_compgen_words "${cur#--incus-migration-mode=}" "auto incus-native files" "--incus-migration-mode="
		;;
	--incus-copy-mode=*)
		_data_migrator_compgen_words "${cur#--incus-copy-mode=}" "pull push relay" "--incus-copy-mode="
		;;
	--config=* | --target-dir=* | --repo-root=* | --source-rsync-path=*)
		_data_migrator_compgen_files "${cur#*=}" "${cur%%=*}="
		;;
	-*)
		_data_migrator_compgen_words "$cur" "${options[*]}"
		;;
	esac
}

complete -F _data_migrator data-migrator
