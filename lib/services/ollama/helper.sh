#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	: "${OLLAMA_URL:=http://127.0.0.1:11434}"
	: "${OLLAMA_URLS:=$OLLAMA_URL}"
	: "${OLLAMA_WAIT_ATTEMPTS:=120}"
	: "${OLLAMA_WAIT_DELAY_SECONDS:=2}"
	OLLAMA_MODELS_DOWNLOADED=0
}

probe_ollama_urls() {
	local url

	for url in $OLLAMA_URLS; do
		if curl -fsS "$url/api/tags" >/dev/null 2>&1; then
			OLLAMA_URL="$url"
			return
		fi
	done

	return 1
}

backend_unit_active_state() {
	local unit="$1"

	systemctl --user show --property=ActiveState --value "$unit" 2>/dev/null
}

current_systemd_user_unit() {
	local unit=""

	if [ -n "${OLLAMA_CURRENT_UNIT:-}" ]; then
		printf '%s\n' "$OLLAMA_CURRENT_UNIT"
		return
	fi

	unit="$(
		awk -F: '{print $3}' /proc/self/cgroup |
			tr '/' '\n' |
			awk '/[.]service$/ { unit = $0 } END { if (unit != "") print unit; else exit 1 }'
	)" || return 1

	if [ -z "$unit" ]; then
		return 1
	fi

	if command -v systemd-escape >/dev/null 2>&1; then
		systemd-escape --unescape "$unit"
	else
		printf '%s\n' "$unit"
	fi
}

after_service_dependencies() {
	local unit="$1"

	systemctl --user show --property=After --value "$unit" 2>/dev/null |
		tr ' ' '\n' |
		awk '/[.]service$/'
}

dependent_service_units() {
	local current_unit dep

	if ! current_unit="$(current_systemd_user_unit)"; then
		return 1
	fi

	while IFS= read -r dep; do
		if [ -z "$dep" ] || [ "$dep" = "$current_unit" ]; then
			continue
		fi
		printf '%s\n' "$dep"
	done < <(after_service_dependencies "$current_unit")
}

all_after_services_inactive() {
	local dep saw_unit=0 state

	while IFS= read -r dep; do
		saw_unit=1
		if ! state="$(backend_unit_active_state "$dep")"; then
			return 1
		fi
		case "$state" in
		inactive | failed)
			;;
		*)
			return 1
			;;
		esac
	done < <(dependent_service_units)

	[ "$saw_unit" -eq 1 ]
}

should_skip_api_wait() {
	all_after_services_inactive
}

wait_for_ollama() {
	local attempt=1

	while [ "$attempt" -le "$OLLAMA_WAIT_ATTEMPTS" ]; do
		if probe_ollama_urls; then
			return
		fi

		if should_skip_api_wait; then
			echo "ollama model pull: dependent service units are inactive; skipping API wait" >&2
			return 2
		fi

		if [ "$attempt" -eq "$OLLAMA_WAIT_ATTEMPTS" ]; then
			return 1
		fi

		sleep "$OLLAMA_WAIT_DELAY_SECONDS"
		attempt=$((attempt + 1))
	done
}

has_model() {
	local model="$1"

	curl -fsS "$OLLAMA_URL/api/tags" |
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
	local model="$1"
	local payload response_file error_message

	if has_model "$model"; then
		echo "ollama model pull: $model already present"
		return
	fi

	echo "ollama model pull: pulling $model"
	payload="$(jq -n --arg model "$model" '{model: $model}')"
	response_file="$(mktemp)"
	if ! curl -fsS -N \
		-H 'Content-Type: application/json' \
		--data "$payload" \
		"$OLLAMA_URL/api/pull" |
		tee "$response_file"; then
		rm -f "$response_file"
		return 1
	fi
	echo

	if ! error_message="$(
		jq -r '
			select(type == "object" and has("error"))
			| .error
		' "$response_file"
	)"; then
		rm -f "$response_file"
		return 1
	fi
	rm -f "$response_file"

	if [ -n "$error_message" ]; then
		echo "ollama model pull: failed to pull $model: $error_message" >&2
		return 1
	fi

	OLLAMA_MODELS_DOWNLOADED=1
}

pull_required_models() {
	local model

	for model in "$@"; do
		pull_model "$model"
	done
}

restart_dependent_services_after_downloads() {
	local dep saw_unit=0

	while IFS= read -r dep; do
		saw_unit=1
		echo "ollama model pull: try-restarting dependent service unit $dep after model download"
		if ! systemctl --user try-restart "$dep"; then
			echo "ollama model pull: failed to try-restart dependent service unit $dep" >&2
			return 1
		fi
	done < <(dependent_service_units)

	if [ "$saw_unit" -eq 0 ]; then
		echo "ollama model pull: no dependent service units found after model download; skipping restart"
	fi
}

main() {
	local wait_status=0

	init_vars

	if [ "$#" -eq 0 ]; then
		echo "ollama model pull: no required models configured"
		return
	fi

	wait_for_ollama || wait_status="$?"
	if [ "$wait_status" -eq 2 ]; then
		return
	fi
	if [ "$wait_status" -ne 0 ]; then
		echo "ollama model pull: no Ollama API available in OLLAMA_URLS=$OLLAMA_URLS; skipping" >&2
		return
	fi

	pull_required_models "$@"
	if [ "$OLLAMA_MODELS_DOWNLOADED" -eq 1 ]; then
		restart_dependent_services_after_downloads
	fi
}

main "$@"
