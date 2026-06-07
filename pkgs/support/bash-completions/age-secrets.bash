_age_secrets_repo_root() {
	local root

	root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
	printf '%s\n' "$root"
}

_age_secrets_managed_paths() {
	local root secrets_file mode="${1:-}"

	root="$(_age_secrets_repo_root)" || return 0
	secrets_file="${root}/data/secrets/default.nix"
	nix eval --json --file "$secrets_file" 2>/dev/null |
		jq -r 'keys[]' 2>/dev/null |
		case "$mode" in
		encrypt | clean) sed 's/[.]age$//' ;;
		*) cat ;;
		esac
}

_age_secrets_mode() {
	local word

	for word in "${COMP_WORDS[@]:1:COMP_CWORD-1}"; do
		case "$word" in
		encrypt | decrypt | clean)
			printf '%s\n' "$word"
			return 0
			;;
		-e)
			printf '%s\n' encrypt
			return 0
			;;
		-d)
			printf '%s\n' decrypt
			return 0
			;;
		-c)
			printf '%s\n' clean
			return 0
			;;
		esac
	done
}

_age_secrets_compgen_words() {
	local cur="$1"
	local words="$2"

	mapfile -t COMPREPLY < <(compgen -W "$words" -- "$cur")
}

_age_secrets() {
	local cur mode
	local -a modes options

	COMPREPLY=()
	cur="${COMP_WORDS[COMP_CWORD]}"
	modes=(encrypt decrypt clean -e -d -c)
	options=(-v --verbose -h --help)
	mode="$(_age_secrets_mode)"

	case "$cur" in
	-*)
		_age_secrets_compgen_words "$cur" "${options[*]} ${modes[*]}"
		;;
	*)
		if [ -z "$mode" ]; then
			_age_secrets_compgen_words "$cur" "${modes[*]} $(_age_secrets_managed_paths)"
		else
			_age_secrets_compgen_words "$cur" "$(_age_secrets_managed_paths "$mode")"
		fi
		;;
	esac
}

complete -F _age_secrets age-secrets age-secrets.sh scripts/age-secrets.sh
