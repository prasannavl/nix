#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	: "${OLLAMA_URL:=http://127.0.0.1:11434}"
	: "${OLLAMA_WAIT_ATTEMPTS:=120}"
	: "${OLLAMA_WAIT_DELAY_SECONDS:=2}"
}

wait_for_ollama() {
	local attempt=1

	while [ "$attempt" -le "$OLLAMA_WAIT_ATTEMPTS" ]; do
		if curl -fsS "${OLLAMA_URL}/api/tags" >/dev/null; then
			return
		fi

		if [ "$attempt" -eq "$OLLAMA_WAIT_ATTEMPTS" ]; then
			echo "ollama model pull: timed out waiting for ${OLLAMA_URL}" >&2
			exit 1
		fi

		sleep "$OLLAMA_WAIT_DELAY_SECONDS"
		attempt=$((attempt + 1))
	done
}

has_model() {
	local model="$1"

	curl -fsS "${OLLAMA_URL}/api/tags" |
		jq -e --arg model "$model" '
			any(
				.models[]?;
				.name == $model
					or .model == $model
					or .name == ($model + ":latest")
					or .model == ($model + ":latest")
			)
		' >/dev/null
}

pull_model() {
	local model="$1" payload=""

	if has_model "$model"; then
		echo "ollama model pull: ${model} already present"
		return
	fi

	echo "ollama model pull: pulling ${model}"
	payload="$(jq -n --arg model "$model" '{model: $model}')"
	curl -fsS -N \
		-H 'Content-Type: application/json' \
		--data "${payload}" \
		"${OLLAMA_URL}/api/pull"
	echo
}

pull_required_models() {
	local model=""

	for model in "$@"; do
		pull_model "${model}"
	done
}

main() {
	init_vars

	if [ "$#" -eq 0 ]; then
		echo "ollama model pull: no required models configured"
		return
	fi

	wait_for_ollama
	pull_required_models "$@"
}

main "$@"
