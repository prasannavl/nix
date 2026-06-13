_nixbot_repo_root() {
	local root

	root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
	printf '%s\n' "$root"
}

_nixbot_explicit_config_path() {
	local i word

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
}

_nixbot_no_override_requested() {
	local i word

	for ((i = 1; i < COMP_CWORD; i++)); do
		word="${COMP_WORDS[i]}"
		if [ "$word" = "--no-override" ]; then
			return 0
		fi
	done

	return 1
}

_nixbot_hosts() {
	local root config=""
	local -a cmd=()

	root="$(_nixbot_repo_root)" || return 0
	config="$(_nixbot_explicit_config_path)"
	cmd=("${root}/scripts/nixbot.sh" --list-hosts --hosts all --log-format plain)
	if [ -n "$config" ]; then
		cmd+=(--config "$config")
	fi
	if _nixbot_no_override_requested; then
		cmd+=(--no-override)
	fi

	"${cmd[@]}" 2>&1 | sed -n 's/^[[:space:]]*-[[:space:]]*\([^[:space:]()]*\).*/\1/p'
}

_nixbot_tf_projects() {
	local root project

	root="$(_nixbot_repo_root)" || return 0
	for project in "$root"/tf/*; do
		[ -d "$project" ] || continue
		[ "$(basename "$project")" != "modules" ] || continue
		printf 'tf/%s\n' "$(basename "$project")"
	done
}

_nixbot_compgen_words() {
	local cur="$1"
	local words="$2"
	local prefix="${3:-}"

	if [ -n "$prefix" ]; then
		mapfile -t COMPREPLY < <(compgen -P "$prefix" -W "$words" -- "$cur")
	else
		mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
	fi
}

_nixbot_compgen_files() {
	local cur="$1"
	local prefix="${2:-}"

	mapfile -t COMPREPLY < <(compgen -f -- "$cur")
	if [ -n "$prefix" ]; then
		COMPREPLY=("${COMPREPLY[@]/#/${prefix}}")
	fi
}

_nixbot_complete_hosts_value() {
	local cur="$1"
	local prefix="" stem="$cur" host
	local comma_prefix="" comma_stem="" space_prefix="" space_stem=""
	local -a candidates=()

	compopt -o nospace 2>/dev/null || true

	if [[ "$cur" == *,* ]]; then
		comma_prefix="${cur%,*},"
		comma_stem="${cur##*,}"
		prefix="$comma_prefix"
		stem="$comma_stem"
	fi
	if [[ "$cur" == *" "* ]]; then
		space_prefix="${cur% *} "
		space_stem="${cur##* }"
		if [ -z "$comma_stem" ] || [ "${#space_stem}" -lt "${#comma_stem}" ]; then
			prefix="$space_prefix"
			stem="$space_stem"
		fi
	fi

	if [[ "$stem" == -* ]]; then
		while IFS= read -r host; do
			candidates+=("-${host}")
		done < <(_nixbot_hosts)
	else
		candidates+=(all)
		while IFS= read -r host; do
			candidates+=("$host")
		done < <(_nixbot_hosts)
	fi

	_nixbot_compgen_words "$stem" "${candidates[*]}"
	for ((i = 0; i < ${#COMPREPLY[@]}; i++)); do
		COMPREPLY[i]="${prefix}${COMPREPLY[i]}"
	done
}

_nixbot() {
	local cur prev eq_opt command=""
	local -a commands options tf_projects

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

	commands=(
		deps check-deps version run deploy build dev-build tf tf-dns
		tf-platform tf-apps check-bootstrap tofu help --list-hosts
	)
	mapfile -t tf_projects < <(_nixbot_tf_projects)
	commands+=("${tf_projects[@]}")

	options=(
		--list-hosts --sha --hosts --goal --build-host --build-host-deploy-mode
		--build-cache-port --build-jobs --build-logs --no-build-logs
		--deploy-jobs --verify-jobs --force --bootstrap --ci-first
		--dirty --dirty-staged --dry --no-override --no-rollback
		--prefix-host-logs --log-format --user --ssh-key --known-hosts --config
		--age-key-file --discover-keys --no-discover-keys --repo-url
		--repo-path --use-repo-script --ci-check-ssh-key-path --ci-trigger
		--ci-host --ci-user --ci-ssh-key --ci-known-hosts --help
	)

	case "$prev" in
	--hosts)
		_nixbot_complete_hosts_value "$cur"
		return 0
		;;
	--goal)
		_nixbot_compgen_words "$cur" "switch boot test dry-activate"
		return 0
		;;
	--build-host)
		_nixbot_compgen_words "$cur" "local $(_nixbot_hosts)"
		return 0
		;;
	--build-host-deploy-mode)
		_nixbot_compgen_words "$cur" "auto cache local-copy"
		return 0
		;;
	--log-format)
		_nixbot_compgen_words "$cur" "auto gh github-actions plain"
		return 0
		;;
	--discover-keys)
		_nixbot_compgen_words "$cur" "auto on off"
		return 0
		;;
	--config | --ssh-key | --age-key-file | --ci-check-ssh-key-path | --repo-path)
		_nixbot_compgen_files "$cur"
		return 0
		;;
	esac

	case "$eq_opt" in
	--hosts)
		_nixbot_complete_hosts_value "$cur"
		return 0
		;;
	--goal)
		_nixbot_compgen_words "$cur" "switch boot test dry-activate"
		return 0
		;;
	--build-host)
		_nixbot_compgen_words "$cur" "local $(_nixbot_hosts)"
		return 0
		;;
	--build-host-deploy-mode)
		_nixbot_compgen_words "$cur" "auto cache local-copy"
		return 0
		;;
	--log-format)
		_nixbot_compgen_words "$cur" "auto gh github-actions plain"
		return 0
		;;
	--discover-keys)
		_nixbot_compgen_words "$cur" "auto on off"
		return 0
		;;
	--config | --ssh-key | --age-key-file | --ci-check-ssh-key-path | --repo-path)
		_nixbot_compgen_files "$cur"
		return 0
		;;
	esac

	case "$cur" in
	--hosts=*)
		_nixbot_complete_hosts_value "${cur#--hosts=}"
		COMPREPLY=("${COMPREPLY[@]/#/--hosts=}")
		;;
	--goal=*)
		_nixbot_compgen_words "${cur#--goal=}" "switch boot test dry-activate" "--goal="
		;;
	--build-host=*)
		_nixbot_compgen_words "${cur#--build-host=}" "local $(_nixbot_hosts)" "--build-host="
		;;
	--build-host-deploy-mode=*)
		_nixbot_compgen_words "${cur#--build-host-deploy-mode=}" "auto cache local-copy" "--build-host-deploy-mode="
		;;
	--log-format=*)
		_nixbot_compgen_words "${cur#--log-format=}" "auto gh github-actions plain" "--log-format="
		;;
	--discover-keys=*)
		_nixbot_compgen_words "${cur#--discover-keys=}" "auto on off" "--discover-keys="
		;;
	--config=* | --ssh-key=* | --age-key-file=* | --ci-check-ssh-key-path=* | --repo-path=*)
		_nixbot_compgen_files "${cur#*=}" "${cur%%=*}="
		;;
	-*)
		_nixbot_compgen_words "$cur" "${options[*]}"
		;;
	*)
		for word in "${COMP_WORDS[@]:1:COMP_CWORD-1}"; do
			case "$word" in
			deps | check-deps | version | run | deploy | build | dev-build | tf | tf-dns | tf-platform | tf-apps | check-bootstrap | tofu | tf/*)
				command="$word"
				break
				;;
			esac
		done
		if [ -z "$command" ]; then
			_nixbot_compgen_words "$cur" "${commands[*]}"
		fi
		;;
	esac
}

complete -F _nixbot nixbot
