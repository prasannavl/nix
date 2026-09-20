#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	: "${LLAMA_ROUTER_URL:=http://127.0.0.1:8080}"
	: "${LLAMA_ROUTER_URLS:=$LLAMA_ROUTER_URL}"
	: "${LLAMA_ROUTER_WAIT_ATTEMPTS:=120}"
	: "${LLAMA_ROUTER_WAIT_DELAY_SECONDS:=2}"
	: "${LLAMA_ROUTER_DOWNLOAD_ATTEMPTS:=900}"
	: "${LLAMA_ROUTER_DOWNLOAD_DELAY_SECONDS:=2}"
	: "${LLAMA_ROUTER_PRESERVED_MODELS:=}"
}

load_ownership_helpers() {
	local helper_path

	helper_path="${MODEL_RECONCILER_OWNERSHIP_LIB:-$(dirname "${BASH_SOURCE[0]}")/../model-reconciler/ownership.sh}"
	# Nix injects the immutable library path.
	# shellcheck disable=SC1090
	source "$helper_path"
	model_reconciler_init_state
}

# Router models are Hugging Face references: "org/repo" with an optional
# ":tag" quant suffix.
valid_model_ref() {
	local model="$1" repo tag

	case "$model" in
	"" | *[[:space:]]* | *//*) return 1 ;;
	esac

	repo="${model%%:*}"
	case "$repo" in
	*/*) ;;
	*) return 1 ;;
	esac
	case "$repo" in
	*/*/*) return 1 ;;
	esac

	if [ "$model" != "$repo" ]; then
		tag="${model#*:}"
		case "$tag" in
		"" | */* | *[[:space:]]*) return 1 ;;
		esac
	fi
}

model_is_required() {
	local model="$1" required_model

	shift
	for required_model in "$@"; do
		if [ "$model" = "$required_model" ]; then
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
		echo "llama-router model reconcile: MODEL_RECONCILER_STATE_FILE is required" >&2
		return 1
	fi
}

validate_required_models() {
	local model

	for model in "$@"; do
		if ! valid_model_ref "$model"; then
			echo "llama-router model load: model $model is not a valid org/repo[:tag] Hugging Face reference" >&2
			return 1
		fi
	done
}

model_is_preserved() {
	local model="$1" preserved_model

	while IFS= read -r preserved_model; do
		[ -n "$preserved_model" ] || continue
		if [ "$model" = "$preserved_model" ]; then
			return 0
		fi
	done <<<"$LLAMA_ROUTER_PRESERVED_MODELS"
	return 1
}

probe_llama_router_urls() {
	local url

	for url in $LLAMA_ROUTER_URLS; do
		if curl -fsS "$url/models" >/dev/null 2>&1; then
			LLAMA_ROUTER_URL="$url"
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

	if [ -n "${LLAMA_ROUTER_CURRENT_UNIT:-}" ]; then
		printf '%s\n' "$LLAMA_ROUTER_CURRENT_UNIT"
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

wait_for_llama_router() {
	local attempt=1

	while [ "$attempt" -le "$LLAMA_ROUTER_WAIT_ATTEMPTS" ]; do
		if probe_llama_router_urls; then
			return
		fi

		if should_skip_api_wait; then
			echo "llama-router model load: dependent service units are inactive; skipping API wait" >&2
			return 2
		fi

		if [ "$attempt" -eq "$LLAMA_ROUTER_WAIT_ATTEMPTS" ]; then
			return 1
		fi

		sleep "$LLAMA_ROUTER_WAIT_DELAY_SECONDS"
		attempt=$((attempt + 1))
	done
}

# Reports one of: absent | unloaded | downloading | downloaded | loading |
# loaded | sleeping | failed | unreachable | unknown.
model_status() {
	local model="$1" response status

	if ! response="$(curl -fsS "$LLAMA_ROUTER_URL/models" 2>/dev/null)"; then
		printf 'unreachable\n'
		return 0
	fi
	if ! status="$(
		printf '%s\n' "$response" |
			jq -r --arg model "$model" '
				first(.data[]? | select(.id == $model) | .status) as $status
				| if $status == null then "absent"
					elif ($status.failed // false) then "failed"
					else $status.value end
			' 2>/dev/null
	)"; then
		printf 'unknown\n'
		return 0
	fi
	# `first` yields no output at all (not null) when no model matches.
	if [ -z "$status" ]; then
		printf 'absent\n'
		return 0
	fi
	printf '%s\n' "$status"
}

request_model_download() {
	local model="$1" payload status

	payload="$(jq -n --arg model "$model" '{model: $model}')"
	if ! curl -fsS -X POST \
		-H 'Content-Type: application/json' \
		--data "$payload" \
		"$LLAMA_ROUTER_URL/models" >/dev/null 2>&1; then
		status="$(model_status "$model")"
		case "$status" in
		downloading | downloaded | unloaded | loading | loaded | sleeping)
			echo "llama-router model download: model $model is already present or downloading"
			;;
		*)
			echo "llama-router model download: failed to request download for model $model" >&2
			return 1
			;;
		esac
	fi
}

wait_for_model_download() {
	local model="$1" attempt=1 status

	while [ "$attempt" -le "$LLAMA_ROUTER_DOWNLOAD_ATTEMPTS" ]; do
		status="$(model_status "$model")"
		case "$status" in
		unloaded | loaded | sleeping)
			echo "llama-router model download: model $model is cached"
			return 0
			;;
		failed)
			echo "llama-router model download: model $model download failed" >&2
			return 1
			;;
		downloading | downloaded | loading | absent)
			;;
		*)
			echo "llama-router model download: unexpected router status '$status' for model $model" >&2
			return 1
			;;
		esac

		if [ "$attempt" -eq "$LLAMA_ROUTER_DOWNLOAD_ATTEMPTS" ]; then
			break
		fi
		sleep "$LLAMA_ROUTER_DOWNLOAD_DELAY_SECONDS"
		attempt=$((attempt + 1))
	done

	echo "llama-router model download: model $model did not reach the cached state within $LLAMA_ROUTER_DOWNLOAD_ATTEMPTS attempts" >&2
	return 1
}

ensure_required_model() {
	local model="$1" status

	status="$(model_status "$model")"
	case "$status" in
	unloaded | loaded | sleeping)
		echo "llama-router model download: model $model already cached"
		;;
	absent)
		if ! request_model_download "$model"; then
			return 1
		fi
		wait_for_model_download "$model"
		;;
	downloading | downloaded | loading)
		echo "llama-router model download: model $model is already in progress; waiting"
		wait_for_model_download "$model"
		;;
	failed)
		echo "llama-router model download: previous download for model $model failed" >&2
		return 1
		;;
	*)
		echo "llama-router model download: unexpected router status '$status' for required model $model" >&2
		return 1
		;;
	esac

	model_reconciler_remember "$model"
}

load_required_models() {
	local model

	for model in "$@"; do
		ensure_required_model "$model"
	done
}

delete_owned_model() {
	local model="$1" status

	status="$(model_status "$model")"
	if [ "$status" = absent ]; then
		echo "llama-router model reconcile: owned model $model already absent"
		return
	fi

	echo "llama-router model reconcile: deleting exact cached model $model"
	curl -fsS -X DELETE -G \
		--data-urlencode "model=$model" \
		"$LLAMA_ROUTER_URL/models" >/dev/null
}

retire_unrequired_owned_models() {
	local model
	local -a owned_models=("${MODEL_RECONCILER_OWNED_MODELS[@]}")

	for model in "${owned_models[@]}"; do
		if model_is_required "$model" "$@"; then
			continue
		fi
		if model_is_preserved "$model"; then
			echo "llama-router model reconcile: preserving $model and relinquishing managed ownership"
			model_reconciler_forget "$model"
			continue
		fi
		delete_owned_model "$model"
		model_reconciler_forget "$model"
	done
}

load_main() {
	local wait_status=0

	init_vars
	validate_ownership_config
	model_reconciler_load_state

	if ! reconciliation_requested "$@"; then
		echo "llama-router model reconcile: no managed models configured"
		return
	fi

	wait_for_llama_router || wait_status="$?"
	if [ "$wait_status" -eq 2 ]; then
		return
	fi
	if [ "$wait_status" -ne 0 ]; then
		echo "llama-router model load: no llama-router API available in LLAMA_ROUTER_URLS=$LLAMA_ROUTER_URLS" >&2
		return 1
	fi

	validate_required_models "$@"
	load_required_models "$@"
	retire_unrequired_owned_models "$@"
}

dispatch_load_worker() {
	local worker_unit poll_deadline active_state sub_state result
	worker_unit="$1"
	shift

	init_vars
	validate_ownership_config

	if ! reconciliation_requested "$@"; then
		echo "llama-router model reconcile: no managed models configured"
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
			echo "llama-router model load: worker failed during dispatch (state=$active_state sub=$sub_state result=$result)" >&2
			return 1
			;;
		inactive:success)
			echo "llama-router model load: worker completed during dispatch"
			return
			;;
		activating:* | active:* | deactivating:* | reloading:*)
			sleep 1
			continue
			;;
		esac

		printf 'llama-router model load: worker entered unexpected state during dispatch (state=%s sub=%s result=%s)\n' \
			"$active_state" "$sub_state" "$result" >&2
		return 1
	done

	echo "llama-router model load: worker accepted; continuing asynchronously"
}

main() {
	local command="${1:-load}"
	load_ownership_helpers

	case "$command" in
	load)
		if [ "$#" -gt 0 ]; then
			shift
		fi
		load_main "$@"
		;;
	dispatch)
		shift
		if [ "$#" -lt 1 ]; then
			echo "llama-router model load: dispatch requires a worker unit" >&2
			return 64
		fi
		dispatch_load_worker "$@"
		;;
	*)
		load_main "$@"
		;;
	esac
}

main "$@"
