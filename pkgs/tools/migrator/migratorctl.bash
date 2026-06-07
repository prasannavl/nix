_migratorctl_repo_root() {
	local root

	root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
	printf '%s\n' "$root"
}

_migratorctl_config_path() {
	local i word root

	for ((i = 1; i < COMP_CWORD; i++)); do
		word="${COMP_WORDS[i]}"
		case "$word" in
		--config=*)
			printf '%s\n' "${word#--config=}"
			return 0
			;;
		--config)
			if ((i + 1 < COMP_CWORD)); then
				printf '%s\n' "${COMP_WORDS[i + 1]}"
				return 0
			fi
			;;
		esac
	done

	root="$(_migratorctl_repo_root)" || return 1
	printf '%s\n' "${root}/${MIGRATOR_NIXBOT_CONFIG:-hosts/nixbot.nix}"
}

_migratorctl_hosts() {
	local config

	config="$(_migratorctl_config_path)" || return 0
	nix eval --json --file "$config" 2>/dev/null |
		jq -r '(.hosts // {}) | keys[]' 2>/dev/null
}

_migratorctl_compgen_words() {
	local cur="$1"
	local words="$2"
	local prefix="${3:-}"

	if [ -n "$prefix" ]; then
		mapfile -t COMPREPLY < <(compgen -P "$prefix" -W "$words" -- "$cur")
	else
		mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
	fi
}

_migratorctl_compgen_files() {
	local cur="$1"
	local prefix="${2:-}"

	mapfile -t COMPREPLY < <(compgen -f -- "$cur")
	if [ -n "$prefix" ]; then
		COMPREPLY=("${COMPREPLY[@]/#/${prefix}}")
	fi
}

_migratorctl() {
	local cur prev eq_opt action="" remote_action="" word
	local -a actions remote_actions remote_options

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
	actions=(on off apply status remote)
	remote_actions=(on off apply status)
	remote_options=(--host --repo-root --config --help)

	for word in "${COMP_WORDS[@]:1:COMP_CWORD-1}"; do
		if [ -z "$action" ]; then
			case "$word" in
			on | off | apply | status | remote)
				action="$word"
				continue
				;;
			esac
		fi
		if [ "$action" = "remote" ] && [ -z "$remote_action" ]; then
			case "$word" in
			on | off | apply | status)
				remote_action="$word"
				;;
			esac
		fi
	done

	case "$prev" in
	--host)
		_migratorctl_compgen_words "$cur" "$(_migratorctl_hosts)"
		return 0
		;;
	--repo-root | --config)
		_migratorctl_compgen_files "$cur"
		return 0
		;;
	esac

	case "$eq_opt" in
	--host)
		_migratorctl_compgen_words "$cur" "$(_migratorctl_hosts)"
		return 0
		;;
	--repo-root | --config)
		_migratorctl_compgen_files "$cur"
		return 0
		;;
	esac

	case "$cur" in
	--host=*)
		_migratorctl_compgen_words "${cur#--host=}" "$(_migratorctl_hosts)" "--host="
		;;
	--repo-root=* | --config=*)
		_migratorctl_compgen_files "${cur#*=}" "${cur%%=*}="
		;;
	-*)
		if [ "$action" = "remote" ]; then
			_migratorctl_compgen_words "$cur" "${remote_options[*]}"
		fi
		;;
	*)
		if [ -z "$action" ]; then
			_migratorctl_compgen_words "$cur" "${actions[*]}"
		elif [ "$action" = "remote" ] && [ -z "$remote_action" ]; then
			_migratorctl_compgen_words "$cur" "${remote_actions[*]}"
		fi
		;;
	esac
}

complete -F _migratorctl migratorctl
