#!/usr/bin/env bash

# Shared fail-closed ownership manifest helpers. Services normally provide a
# systemd StateDirectory plus MODEL_RECONCILER_STATE_NAME. Tests and standalone
# callers may provide MODEL_RECONCILER_STATE_FILE directly.

declare -a MODEL_RECONCILER_OWNED_MODELS=()

model_reconciler_init_state() {
	if [ -n "${MODEL_RECONCILER_STATE_FILE:-}" ]; then
		return
	fi
	if [ -z "${STATE_DIRECTORY:-}" ] || [ -z "${MODEL_RECONCILER_STATE_NAME:-}" ]; then
		echo "model reconcile: STATE_DIRECTORY and MODEL_RECONCILER_STATE_NAME are required" >&2
		return 1
	fi
	case "$MODEL_RECONCILER_STATE_NAME" in
	"" | "." | ".." | */*)
		echo "model reconcile: unsafe ownership manifest name $MODEL_RECONCILER_STATE_NAME" >&2
		return 1
		;;
	esac
	MODEL_RECONCILER_STATE_FILE="${STATE_DIRECTORY%/}/$MODEL_RECONCILER_STATE_NAME"
	export MODEL_RECONCILER_STATE_FILE
}

model_reconciler_state_exists() {
	if [ -e "$MODEL_RECONCILER_STATE_FILE" ]; then
		return
	fi
	[ -n "${MODEL_RECONCILER_LEGACY_STATE_FILE:-}" ] &&
		[ -e "$MODEL_RECONCILER_LEGACY_STATE_FILE" ]
}

model_reconciler_load_state() {
	local state_file="$MODEL_RECONCILER_STATE_FILE" migrate=0

	MODEL_RECONCILER_OWNED_MODELS=()
	if [ ! -e "$state_file" ] &&
		[ -n "${MODEL_RECONCILER_LEGACY_STATE_FILE:-}" ] &&
		[ -e "$MODEL_RECONCILER_LEGACY_STATE_FILE" ]; then
		state_file="$MODEL_RECONCILER_LEGACY_STATE_FILE"
		migrate=1
	fi
	if [ ! -e "$state_file" ]; then
		return
	fi
	if [ ! -f "$state_file" ] ||
		! jq -e '
			type == "object"
			and .version == 1
			and (.models | type == "array")
			and all(.models[];
				type == "string"
				and length > 0
				and (contains("\n") | not)
			)
			and ((.models | unique | length) == (.models | length))
		' "$state_file" >/dev/null; then
		echo "model reconcile: invalid ownership manifest $state_file; refusing to mutate backend state" >&2
		return 1
	fi
	mapfile -t MODEL_RECONCILER_OWNED_MODELS < <(jq -r '.models[]' "$state_file")
	if [ "$migrate" -eq 1 ]; then
		model_reconciler_save_state
		echo "model reconcile: imported ownership manifest from $state_file"
	fi
}

model_reconciler_save_state() {
	local state_file="$MODEL_RECONCILER_STATE_FILE" state_dir state_tmp

	state_dir="$(dirname "$state_file")"
	state_tmp="${state_file}.new"
	if [ "${#MODEL_RECONCILER_OWNED_MODELS[@]}" -eq 0 ] &&
		{ [ -z "${MODEL_RECONCILER_LEGACY_STATE_FILE:-}" ] || [ ! -e "$MODEL_RECONCILER_LEGACY_STATE_FILE" ]; }; then
		rm -f -- "$state_tmp" "$state_file"
		return
	fi
	mkdir -p -- "$state_dir"
	(
		umask 077
		jq -n --args '$ARGS.positional | unique | {version: 1, models: .}' \
			-- "${MODEL_RECONCILER_OWNED_MODELS[@]}" >"$state_tmp"
	)
	mv -f -- "$state_tmp" "$state_file"
}

model_reconciler_owns() {
	local model="$1" owned_model

	for owned_model in "${MODEL_RECONCILER_OWNED_MODELS[@]}"; do
		if [ "$owned_model" = "$model" ]; then
			return 0
		fi
	done
	return 1
}

model_reconciler_remember() {
	local model="$1"

	if model_reconciler_owns "$model"; then
		return
	fi
	MODEL_RECONCILER_OWNED_MODELS+=("$model")
	model_reconciler_save_state
}

model_reconciler_forget() {
	local model="$1" owned_model
	local -a retained=()

	for owned_model in "${MODEL_RECONCILER_OWNED_MODELS[@]}"; do
		if [ "$owned_model" != "$model" ]; then
			retained+=("$owned_model")
		fi
	done
	MODEL_RECONCILER_OWNED_MODELS=("${retained[@]}")
	model_reconciler_save_state
}
