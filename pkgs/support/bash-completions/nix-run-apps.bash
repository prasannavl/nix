_repo_nix_run_completion_bridge_dir() {
	local source_path="${BASH_SOURCE[0]}"

	cd "$(dirname "$source_path")/../../.." && pwd -P
}

_repo_nix_run_completion_source_once() {
	local path="$1"

	# shellcheck source=/dev/null
	source "$path"
}

_repo_nix_run_completion_current_nix_func() {
	local existing_completion existing_func=""

	existing_completion="$(complete -p nix 2>/dev/null || true)"
	if [[ "$existing_completion" =~ [[:space:]]-F[[:space:]]+([^[:space:]]+) ]]; then
		existing_func="${BASH_REMATCH[1]}"
	fi
	printf '%s\n' "$existing_func"
}

_repo_nix_run_completion_source_bash_completion() {
	local data_dir
	local support_file

	declare -F _get_comp_words_by_ref >/dev/null &&
		declare -F __ltrim_colon_completions >/dev/null &&
		return 0

	for data_dir in ${XDG_DATA_DIRS//:/ }; do
		if [ -f "${data_dir}/bash-completion/bash_completion" ]; then
			# shellcheck source=/dev/null
			source "${data_dir}/bash-completion/bash_completion"
			break
		fi
	done

	for support_file in \
		/run/current-system/sw/share/bash-completion/bash_completion \
		/usr/share/bash-completion/bash_completion; do
		if [ -f "$support_file" ]; then
			# shellcheck source=/dev/null
			source "$support_file"
			break
		fi
	done
}

_repo_nix_run_completion_source_native_nix() {
	local data_dir completion_file nix_bin nix_prefix

	_repo_nix_run_completion_source_bash_completion

	for data_dir in ${XDG_DATA_DIRS//:/ }; do
		completion_file="${data_dir}/bash-completion/completions/nix"
		if [ -f "$completion_file" ]; then
			# shellcheck source=/dev/null
			source "$completion_file"
			return 0
		fi
	done

	nix_bin="$(command -v nix 2>/dev/null || true)"
	if [ -n "$nix_bin" ]; then
		nix_prefix="${nix_bin%/bin/nix}"
		completion_file="${nix_prefix}/share/bash-completion/completions/nix"
		if [ -f "$completion_file" ]; then
			# shellcheck source=/dev/null
			source "$completion_file"
			return 0
		fi
	fi
}

_repo_nix_run_completion_func_is_usable() {
	local func="$1"

	[ -n "$func" ] &&
		[ "$func" != "_repo_nix_completion" ] &&
		[ "$func" != "_completion_loader" ] &&
		declare -F "$func" >/dev/null
}

_repo_nix_run_completion_resolve_native_nix_func() {
	local existing_func

	existing_func="$(_repo_nix_run_completion_current_nix_func)"
	if _repo_nix_run_completion_func_is_usable "$existing_func"; then
		printf '%s\n' "$existing_func"
		return 0
	fi

	_repo_nix_run_completion_source_native_nix
	existing_func="$(_repo_nix_run_completion_current_nix_func)"
	if _repo_nix_run_completion_func_is_usable "$existing_func"; then
		printf '%s\n' "$existing_func"
	fi
}

_repo_nix_run_completion_init() {
	local repo_root existing_func

	repo_root="$(_repo_nix_run_completion_bridge_dir)"
	_repo_nix_run_completion_source_once "${repo_root}/pkgs/tools/nixbot/nixbot.bash"
	_repo_nix_run_completion_source_once "${repo_root}/pkgs/tools/data-migrator/data-migrator.bash"
	_repo_nix_run_completion_source_once "${repo_root}/pkgs/tool/migration-manager/migration-manager.bash"

	existing_func="${_REPO_NIX_RUN_COMPLETION_PREV_NIX:-}"
	if ! _repo_nix_run_completion_func_is_usable "$existing_func"; then
		existing_func="$(_repo_nix_run_completion_resolve_native_nix_func)"
		_REPO_NIX_RUN_COMPLETION_PREV_NIX="$existing_func"
	fi
}

_repo_nix_run_completion_app_completion() {
	local app_ref="$1"

	case "$app_ref" in
	.#nixbot | ./#nixbot | /*"#nixbot")
		printf '%s\n%s\n' nixbot _nixbot
		;;
	.#data-migrator | ./#data-migrator | /*"#data-migrator")
		printf '%s\n%s\n' data-migrator _data_migrator
		;;
	.#migration-manager | ./#migration-manager | /*"#migration-manager")
		printf '%s\n%s\n' migration-manager _migration_manager
		;;
	esac
}

_repo_nix_run_completion_restore_completion_state() {
	local words_name="$1"
	local cword="$2"
	local line="$3"
	local point="$4"
	local -n words_ref="$words_name"

	COMP_WORDS=("${words_ref[@]}")
	COMP_CWORD="$cword"
	COMP_LINE="$line"
	COMP_POINT="$point"
}

_repo_nix_run_completion_set_synthetic_state() {
	local command_name="$1"
	local sep_index="$2"
	local i

	COMP_WORDS=("$command_name")
	for ((i = sep_index + 1; i < ${#_repo_nix_run_completion_original_words[@]}; i++)); do
		COMP_WORDS+=("${_repo_nix_run_completion_original_words[i]}")
	done
	COMP_CWORD=$((COMP_CWORD - sep_index))
	COMP_LINE="${COMP_WORDS[*]}"
	COMP_POINT="${#COMP_LINE}"
}

_repo_nix_run_completion_delegate() {
	local i app_ref="" sep_index=-1 command_name="" completion_func=""
	local original_cword="$COMP_CWORD"
	local original_line="$COMP_LINE"
	local original_point="$COMP_POINT"
	local -a resolved=()
	local -a _repo_nix_run_completion_original_words=("${COMP_WORDS[@]}")

	[ "${COMP_WORDS[0]:-}" = "nix" ] || return 1
	[ "${COMP_WORDS[1]:-}" = "run" ] || return 1

	for ((i = 2; i < ${#COMP_WORDS[@]}; i++)); do
		if [ "${COMP_WORDS[i]}" = "--" ]; then
			sep_index="$i"
			break
		fi
		if [ -z "$app_ref" ] && [[ "${COMP_WORDS[i]}" != -* ]]; then
			app_ref="${COMP_WORDS[i]}"
		fi
	done

	[ "$sep_index" -ge 0 ] || return 1
	[ "$COMP_CWORD" -gt "$sep_index" ] || return 1
	[ -n "$app_ref" ] || return 1

	mapfile -t resolved < <(_repo_nix_run_completion_app_completion "$app_ref")
	[ "${#resolved[@]}" -eq 2 ] || return 1
	command_name="${resolved[0]}"
	completion_func="${resolved[1]}"
	declare -F "$completion_func" >/dev/null || return 1

	_repo_nix_run_completion_set_synthetic_state "$command_name" "$sep_index"
	"$completion_func"
	_repo_nix_run_completion_restore_completion_state \
		_repo_nix_run_completion_original_words \
		"$original_cword" \
		"$original_line" \
		"$original_point"
	return 0
}

_repo_nix_run_completion_native_nix() {
	local cur="${COMP_WORDS[COMP_CWORD]:-}"
	local completion have_type=""

	while IFS= read -r line; do
		completion="${line%%	*}"
		if [ -z "$have_type" ]; then
			have_type=1
			case "$completion" in
			filenames)
				compopt -o filenames 2>/dev/null || true
				;;
			attrs)
				compopt -o nospace 2>/dev/null || true
				;;
			esac
			continue
		fi

		if [[ "$cur" == *=* ]]; then
			completion="${completion#*=}"
		fi
		COMPREPLY+=("$completion")
	done < <(NIX_GET_COMPLETIONS=$COMP_CWORD "${COMP_WORDS[@]}" 2>/dev/null)

	if declare -F __ltrim_colon_completions >/dev/null; then
		__ltrim_colon_completions "$cur"
	fi
	[ "$have_type" = 1 ]
}

_repo_nix_run_completion_fallback() {
	local prev_func="${_REPO_NIX_RUN_COMPLETION_PREV_NIX:-}"

	if _repo_nix_run_completion_native_nix; then
		return 0
	fi

	if ! _repo_nix_run_completion_func_is_usable "$prev_func"; then
		prev_func="$(_repo_nix_run_completion_resolve_native_nix_func)"
		_REPO_NIX_RUN_COMPLETION_PREV_NIX="$prev_func"
	fi
	if _repo_nix_run_completion_func_is_usable "$prev_func"; then
		"$prev_func"
	fi
}

_repo_nix_completion() {
	COMPREPLY=()
	if _repo_nix_run_completion_delegate; then
		return 0
	fi
	_repo_nix_run_completion_fallback
}

_repo_nix_run_completion_init
complete -F _repo_nix_completion nix
complete -F _nixbot ./scripts/nixbot.sh scripts/nixbot.sh
