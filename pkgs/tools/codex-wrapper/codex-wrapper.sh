#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
	printf 'Usage: %s [-u] [-xNUM] [-xswap NUM] [codex args...]\n' "$(name)" >&2
}

help() {
	cat <<EOF
$(name) wrapper options:
  -u                 Pass --dangerously-bypass-approvals-and-sandbox to Codex.
  -xNUM, -x NUM      Run Codex with auth.NUM.json mounted as auth.json.
  -xswap NUM         Permanently swap auth.json with auth.NUM.json.

Codex help:
EOF
}

name() {
	printf '%s\n' "${CODEX_WRAPPER_NAME:-${0##*/}}"
}

auth_dir() {
	if [[ -n "${CODEX_HOME:-}" ]]; then
		printf '%s\n' "$CODEX_HOME"
	else
		printf '%s/.codex\n' "$HOME"
	fi
}

slot_file() {
	local dir="$1" slot="$2"
	printf '%s/auth.%s.json\n' "$dir" "$slot"
}

state_file() {
	local dir="$1"
	printf '%s/auth.current\n' "$dir"
}

validate_slot() {
	local slot="$1"
	if [[ ! "$slot" =~ ^[0-9]+$ ]]; then
		printf '%s: auth slot must be numeric: %s\n' "$(name)" "$slot" >&2
		exit 2
	fi
}

ensure_slot_file() {
	local slot="$1" dir target_file

	validate_slot "$slot"
	dir="$(auth_dir)"
	mkdir -p "$dir"
	target_file="$(slot_file "$dir" "$slot")"
	if [[ ! -f "$target_file" ]]; then
		: >"$target_file"
	fi
	printf '%s\n' "$target_file"
}

rename_no_clobber() {
	local from="$1" to="$2"
	if [[ -e "$to" ]]; then
		printf '%s: refusing to overwrite existing auth file: %s\n' "$(name)" "$to" >&2
		exit 1
	fi
	mv -T -- "$from" "$to"
}

current_slot_from_state() {
	local dir="$1" slot state

	state="$(state_file "$dir")"
	if [[ -f "$state" ]]; then
		read -r slot <"$state" || true
		if [[ "${slot:-}" =~ ^[0-9]+$ && ! -e "$(slot_file "$dir" "$slot")" ]]; then
			printf '%s\n' "$slot"
			return 0
		fi
	fi
	return 1
}

current_slot_from_only_auth_json() {
	local dir="$1" file count=0

	[[ -f "$dir/auth.json" ]] || return 1

	shopt -s nullglob
	for file in "$dir"/auth.[0-9]*.json; do
		if [[ -f "$file" ]]; then
			count=$((count + 1))
		fi
	done
	shopt -u nullglob

	if [[ "$count" -eq 0 ]]; then
		printf '0\n'
		return 0
	fi
	return 1
}

detect_current_slot_for_switch() {
	local dir="$1" slot

	if slot="$(current_slot_from_state "$dir")"; then
		printf '%s\n' "$slot"
		return 0
	fi

	if slot="$(current_slot_from_only_auth_json "$dir")"; then
		printf '%s\n' "$slot"
		return 0
	fi

	printf '%s: cannot infer current auth slot for %s/auth.json\n' "$(name)" "$dir" >&2
	printf '%s: run with -xswap only when auth.current names the active slot, or when only auth.json exists.\n' "$(name)" >&2
	exit 1
}

record_current_slot() {
	local dir="$1" slot="$2"
	printf '%s\n' "$slot" >"$(state_file "$dir")"
}

switch_auth() {
	local target="$1" dir target_file current current_file

	validate_slot "$target"
	dir="$(auth_dir)"
	mkdir -p "$dir"
	target_file="$(slot_file "$dir" "$target")"

	if [[ ! -f "$dir/auth.json" ]]; then
		target_file="$(ensure_slot_file "$target")"
		rename_no_clobber "$target_file" "$dir/auth.json"
		record_current_slot "$dir" "$target"
		return 0
	fi

	current="$(detect_current_slot_for_switch "$dir")"
	if [[ "$current" == "$target" ]]; then
		record_current_slot "$dir" "$target"
		return 0
	fi

	target_file="$(ensure_slot_file "$target")"
	current_file="$(slot_file "$dir" "$current")"
	rename_no_clobber "$dir/auth.json" "$current_file"
	rename_no_clobber "$target_file" "$dir/auth.json"
	record_current_slot "$dir" "$target"
}

run_with_overlay_auth() {
	local target="$1" dir target_file auth_file
	shift

	target_file="$(ensure_slot_file "$target")"
	dir="$(auth_dir)"
	auth_file="$dir/auth.json"
	if [[ ! -f "$auth_file" ]]; then
		: >"$auth_file"
	fi

	exec bwrap \
		--dev-bind / / \
		--bind "$target_file" "$auth_file" \
		-- \
		"$CODEX_REAL" "$@"
}

take_slot_arg() {
	local opt="$1" value="${2:-}"

	if [[ -z "$value" ]]; then
		printf '%s: %s requires a numeric slot\n' "$(name)" "$opt" >&2
		exit 2
	fi
	printf '%s\n' "$value"
}

parse_args() {
	local arg
	AUTH_MODE=""
	AUTH_SLOT=""
	SHOW_HELP=""
	CODEX_ARGS=()

	while (($# > 0)); do
		arg="$1"
		case "$arg" in
		-h | --help)
			SHOW_HELP="1"
			CODEX_ARGS+=("$arg")
			shift
			;;
		-u)
			CODEX_ARGS+=(--dangerously-bypass-approvals-and-sandbox)
			shift
			;;
		-xswap=*)
			AUTH_MODE="switch"
			AUTH_SLOT="${arg#-xswap=}"
			shift
			;;
		-xswap)
			AUTH_MODE="switch"
			AUTH_SLOT="$(take_slot_arg "$arg" "${2:-}")"
			shift 2
			;;
		-x[0-9]*)
			AUTH_MODE="overlay"
			AUTH_SLOT="${arg#-x}"
			shift
			;;
		-x)
			AUTH_MODE="overlay"
			AUTH_SLOT="$(take_slot_arg "$arg" "${2:-}")"
			shift 2
			;;
		--)
			shift
			CODEX_ARGS+=("$@")
			break
			;;
		*)
			CODEX_ARGS+=("$arg")
			shift
			;;
		esac
	done
}

main() {
	if [[ -z "${CODEX_REAL:-}" ]]; then
		printf '%s: CODEX_REAL is not set\n' "$(name)" >&2
		exit 1
	fi

	parse_args "$@"

	if [[ -n "$SHOW_HELP" ]]; then
		help
	fi

	case "$AUTH_MODE" in
	"")
		exec "$CODEX_REAL" "${CODEX_ARGS[@]}"
		;;
	overlay)
		run_with_overlay_auth "$AUTH_SLOT" "${CODEX_ARGS[@]}"
		;;
	switch)
		switch_auth "$AUTH_SLOT"
		if ((${#CODEX_ARGS[@]} == 0)); then
			exit 0
		fi
		exec "$CODEX_REAL" "${CODEX_ARGS[@]}"
		;;
	*)
		usage
		exit 2
		;;
	esac
}

main "$@"
