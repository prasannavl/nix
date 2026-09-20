#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	: "${OLLAMA_URL:=http://127.0.0.1:11434}"
	: "${OLLAMA_URLS:=$OLLAMA_URL}"
	: "${OLLAMA_WAIT_ATTEMPTS:=120}"
	: "${OLLAMA_WAIT_DELAY_SECONDS:=2}"
	: "${OLLAMA_PRESERVED_MODELS:=}"
}

load_ownership_helpers() {
	local helper_path

	helper_path="${MODEL_RECONCILER_OWNERSHIP_LIB:-$(dirname "${BASH_SOURCE[0]}")/../model-reconciler/ownership.sh}"
	# Nix injects the immutable library path.
	# shellcheck disable=SC1090
	source "$helper_path"
	model_reconciler_init_state
}

canonical_model_name() {
	local model="$1" final_component

	final_component="${model##*/}"
	case "$final_component" in
	*:*)
		printf '%s\n' "$model"
		;;
	*)
		printf '%s:latest\n' "$model"
		;;
	esac
}

model_is_required() {
	local model required_model

	model="$(canonical_model_name "$1")"
	shift
	for required_model in "$@"; do
		if [ "$model" = "$(canonical_model_name "$required_model")" ]; then
			return 0
		fi
	done
	return 1
}

reconciliation_requested() {
	[ "$#" -gt 0 ] || model_reconciler_state_exists
}

validate_ownership_config() {
	if [ -z "${MODEL_RECONCILER_STATE_FILE:-}" ]; then
		echo "ollama model reconcile: MODEL_RECONCILER_STATE_FILE is required" >&2
		return 1
	fi
}

model_is_preserved() {
	local model preserved_model

	model="$(canonical_model_name "$1")"
	while IFS= read -r preserved_model; do
		[ -n "$preserved_model" ] || continue
		if [ "$model" = "$(canonical_model_name "$preserved_model")" ]; then
			return 0
		fi
	done <<<"$OLLAMA_PRESERVED_MODELS"
	return 1
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
	local old_ifs path part unit=""

	if [ -n "${OLLAMA_CURRENT_UNIT:-}" ]; then
		printf '%s\n' "$OLLAMA_CURRENT_UNIT"
		return
	fi

	while IFS=: read -r _hierarchy _controllers path; do
		old_ifs="$IFS"
		IFS='/'
		for part in $path; do
			case "$part" in
			*.service)
				unit="$part"
				;;
			esac
		done
		IFS="$old_ifs"
	done </proc/self/cgroup

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

	systemctl --user show --property=After --value "$unit" 2>/dev/null
}

dependent_service_units() {
	local current_unit dep

	if ! current_unit="$(current_systemd_user_unit)"; then
		return 1
	fi

	for dep in $(after_service_dependencies "$current_unit"); do
		if [ -z "$dep" ] || [ "$dep" = "$current_unit" ]; then
			continue
		fi
		case "$dep" in
		*.service)
			;;
		*)
			continue
			;;
		esac
		printf '%s\n' "$dep"
	done
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
	local model
	local payload response_file error_message

	model="$(canonical_model_name "$1")"
	if has_model "$model"; then
		echo "ollama model pull: $model already present"
		if ! model_reconciler_owns "$model"; then
			echo "ollama model reconcile: adopting existing model $model"
			model_reconciler_remember "$model"
		fi
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

	model_reconciler_remember "$model"
}

pull_required_models() {
	local model

	for model in "$@"; do
		pull_model "$model"
	done
}

remove_model() {
	local model="$1"
	local payload

	if ! has_model "$model"; then
		echo "ollama model reconcile: model $model already absent"
		return
	fi

	echo "ollama model reconcile: removing model $model"
	payload="$(jq -n --arg model "$model" '{model: $model}')"
	curl -fsS \
		-X DELETE \
		-H 'Content-Type: application/json' \
		--data "$payload" \
		"$OLLAMA_URL/api/delete" >/dev/null
}

retire_unrequired_owned_models() {
	local model
	local -a owned_models=("${MODEL_RECONCILER_OWNED_MODELS[@]}")

	for model in "${owned_models[@]}"; do
		if model_is_required "$model" "$@"; then
			continue
		fi
		if model_is_preserved "$model"; then
			echo "ollama model reconcile: preserving $model and relinquishing managed ownership"
			model_reconciler_forget "$model"
			continue
		fi
		remove_model "$model"
		model_reconciler_forget "$model"
	done
}

pull_main() {
	local wait_status=0

	init_vars
	validate_ownership_config
	model_reconciler_load_state

	if ! reconciliation_requested "$@"; then
		echo "ollama model reconcile: no managed models configured"
		return
	fi

	wait_for_ollama || wait_status="$?"
	if [ "$wait_status" -eq 2 ]; then
		return
	fi
	if [ "$wait_status" -ne 0 ]; then
		echo "ollama model pull: no Ollama API available in OLLAMA_URLS=$OLLAMA_URLS" >&2
		return 1
	fi

	pull_required_models "$@"
	retire_unrequired_owned_models "$@"
}

dispatch_pull_worker() {
	local worker_unit poll_deadline active_state sub_state result
	worker_unit="$1"
	shift

	init_vars
	validate_ownership_config

	if ! reconciliation_requested "$@"; then
		echo "ollama model reconcile: no managed models configured"
		return
	fi

	systemctl --user reset-failed "$worker_unit" >/dev/null 2>&1 || true
	systemctl --user restart --no-block "$worker_unit"

	poll_deadline="$(($(date +%s) + 10))"
	while [ "$(date +%s)" -lt "$poll_deadline" ]; do
		active_state="$(systemctl --user show --property=ActiveState --value "$worker_unit" 2>/dev/null || true)"
		sub_state="$(systemctl --user show --property=SubState --value "$worker_unit" 2>/dev/null || true)"
		result="$(systemctl --user show --property=Result --value "$worker_unit" 2>/dev/null || true)"

		case "$active_state:$result" in
		failed:*)
			echo "ollama model pull: worker failed during dispatch (state=$active_state sub=$sub_state result=$result)" >&2
			return 1
			;;
		inactive:success)
			echo "ollama model pull: worker completed during dispatch"
			return
			;;
		activating:* | active:* | deactivating:* | reloading:*)
			sleep 1
			continue
			;;
		esac

		printf 'ollama model pull: worker entered unexpected state during dispatch (state=%s sub=%s result=%s)\n' \
			"$active_state" "$sub_state" "$result" >&2
		return 1
	done

	echo "ollama model pull: worker accepted; continuing asynchronously"
}

main() {
	local command="${1:-pull}"
	load_ownership_helpers

	case "$command" in
	pull)
		if [ "$#" -gt 0 ]; then
			shift
		fi
		pull_main "$@"
		;;
	dispatch)
		shift
		if [ "$#" -lt 1 ]; then
			echo "ollama model pull: dispatch requires a worker unit" >&2
			return 64
		fi
		dispatch_pull_worker "$@"
		;;
	*)
		pull_main "$@"
		;;
	esac
}

main "$@"
