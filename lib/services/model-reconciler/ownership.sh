#!/usr/bin/env bash

# Shared fail-closed ownership manifest helpers. Callers must set
# MODEL_RECONCILER_STATE_FILE and provide jq, coreutils, and Bash.

declare -a MODEL_RECONCILER_OWNED_MODELS=()

model_reconciler_load_state() {
	local state_file="$MODEL_RECONCILER_STATE_FILE"

	MODEL_RECONCILER_OWNED_MODELS=()
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
}

model_reconciler_save_state() {
	local state_file="$MODEL_RECONCILER_STATE_FILE" state_dir state_tmp

	state_dir="$(dirname "$state_file")"
	mkdir -p -- "$state_dir"
	state_tmp="${state_file}.new"
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
