#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	: "${LLAMA_ROUTER_URL:=http://127.0.0.1:8080}"
	: "${LLAMA_ROUTER_URLS:=$LLAMA_ROUTER_URL}"
	: "${LLAMA_ROUTER_WAIT_ATTEMPTS:=120}"
	: "${LLAMA_ROUTER_WAIT_DELAY_SECONDS:=2}"
	: "${LLAMA_ROUTER_LOAD_ATTEMPTS:=900}"
	: "${LLAMA_ROUTER_LOAD_DELAY_SECONDS:=2}"
	: "${LLAMA_ROUTER_RETIRED_MODELS:=}"
	LLAMA_ROUTER_MODELS_CHANGED=0
}

# Router models are Hugging Face references: "org/repo" with an optional
# ":tag" quant suffix. The repo part also names the HF cache directory that
# retirement pruning removes, so the shape is enforced here as well as in the
# Nix assertion layer.
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

model_repo_dir() {
	local repo="${1%%:*}"

	printf 'models--%s\n' "${repo//\//--}"
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
	[ "$#" -gt 0 ] || [ -n "$LLAMA_ROUTER_RETIRED_MODELS" ]
}

validate_cache_dir() {
	if [ -z "${LLAMA_ROUTER_CACHE_DIR:-}" ]; then
		echo "llama-router model reconcile: LLAMA_ROUTER_CACHE_DIR is required" >&2
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

validate_retired_models() {
	local model

	while IFS= read -r model; do
		[ -n "$model" ] || continue
		if model_is_required "$model" "$@"; then
			echo "llama-router model reconcile: model $model cannot be both required and retired" >&2
			return 1
		fi
		if ! valid_model_ref "$model"; then
			echo "llama-router model reconcile: model $model is not a valid org/repo[:tag] Hugging Face reference" >&2
			return 1
		fi
	done <<<"$LLAMA_ROUTER_RETIRED_MODELS"
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

# Reports one of: absent | unloaded | loading | loaded | sleeping | failed |
# unreachable | unknown. "failed" marks an unload-with-nonzero-exit child,
# which at this llama.cpp revision is also how interrupted downloads appear.
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

# A finished download leaves a GGUF snapshot behind in the HF cache layout
# (blobs land first, snapshot symlinks only after the download completes), so
# this distinguishes "download failed" from "weights are cached but the child
# could not load them" without any router-side status for downloads.
model_cache_has_weights() {
	local repo_dir="$1"
	local -a files=()

	shopt -s nullglob
	files=(
		"$LLAMA_ROUTER_CACHE_DIR/$repo_dir"/snapshots/*/*.gguf
		"$LLAMA_ROUTER_CACHE_DIR/$repo_dir"/snapshots/*/**/*.gguf
	)
	shopt -u nullglob

	[ "${#files[@]}" -gt 0 ]
}

handle_model_load_failure() {
	local model="$1" repo_dir

	repo_dir="$(model_repo_dir "$model")"
	if model_cache_has_weights "$repo_dir"; then
		echo "llama-router model load: model $model failed to load despite cached weights (likely a resource limit such as VRAM); keeping it cached for recovery" >&2
		return 0
	fi
	echo "llama-router model load: model $model failed to load and has no cached weights; the download may have failed" >&2
	return 1
}

request_model_load() {
	local model="$1" payload status

	payload="$(jq -n --arg model "$model" '{model: $model}')"
	if ! curl -fsS -X POST \
		-H 'Content-Type: application/json' \
		--data "$payload" \
		"$LLAMA_ROUTER_URL/models/load" >/dev/null 2>&1; then
		status="$(model_status "$model")"
		case "$status" in
		loading | loaded | sleeping)
			echo "llama-router model load: model $model is already running"
			;;
		*)
			echo "llama-router model load: failed to request load for model $model" >&2
			return 1
			;;
		esac
	fi
}

wait_for_model_load() {
	local model="$1" attempt=1 status

	while [ "$attempt" -le "$LLAMA_ROUTER_LOAD_ATTEMPTS" ]; do
		status="$(model_status "$model")"
		case "$status" in
		loaded | sleeping)
			echo "llama-router model load: model $model is loaded"
			return 0
			;;
		failed)
			handle_model_load_failure "$model"
			return
			;;
		loading | unloaded)
			;;
		*)
			echo "llama-router model load: unexpected router status '$status' while loading model $model" >&2
			return 1
			;;
		esac

		if [ "$attempt" -eq "$LLAMA_ROUTER_LOAD_ATTEMPTS" ]; then
			break
		fi
		sleep "$LLAMA_ROUTER_LOAD_DELAY_SECONDS"
		attempt=$((attempt + 1))
	done

	echo "llama-router model load: model $model did not reach the loaded state within $LLAMA_ROUTER_LOAD_ATTEMPTS attempts" >&2
	return 1
}

ensure_required_model() {
	local model="$1" status

	status="$(model_status "$model")"
	case "$status" in
	loaded | sleeping)
		echo "llama-router model load: model $model already loaded"
		return
		;;
	loading)
		echo "llama-router model load: model $model is already loading; waiting for it"
		;;
	unloaded)
		if ! request_model_load "$model"; then
			return 1
		fi
		;;
	failed)
		echo "llama-router model load: previous load attempt for $model failed; retrying"
		if ! request_model_load "$model"; then
			return 1
		fi
		;;
	*)
		echo "llama-router model load: unexpected router status '$status' for required model $model" >&2
		return 1
		;;
	esac
	wait_for_model_load "$model"
}

load_required_models() {
	local model

	for model in "$@"; do
		ensure_required_model "$model"
	done
}

unload_model() {
	local model="$1" payload status

	status="$(model_status "$model")"
	case "$status" in
	loaded | loading | sleeping)
		echo "llama-router model reconcile: unloading model $model"
		payload="$(jq -n --arg model "$model" '{model: $model}')"
		if ! curl -fsS -X POST \
			-H 'Content-Type: application/json' \
			--data "$payload" \
			"$LLAMA_ROUTER_URL/models/unload" >/dev/null 2>&1; then
			echo "llama-router model reconcile: failed to unload model $model" >&2
			return 1
		fi
		LLAMA_ROUTER_MODELS_CHANGED=1
		;;
	absent | unloaded | failed)
		echo "llama-router model reconcile: model $model is not running; skipping unload"
		;;
	*)
		echo "llama-router model reconcile: unexpected router status '$status' while unloading model $model" >&2
		return 1
		;;
	esac
}

unload_retired_models() {
	local model

	while IFS= read -r model; do
		[ -n "$model" ] || continue
		unload_model "$model"
	done <<<"$LLAMA_ROUTER_RETIRED_MODELS"
	return 0
}

prune_model_cache() {
	local model="$1" repo_dir cache_path

	repo_dir="$(model_repo_dir "$model")"
	cache_path="$LLAMA_ROUTER_CACHE_DIR/$repo_dir"
	if [ ! -e "$cache_path" ]; then
		echo "llama-router model reconcile: cache for model $model already absent"
		return
	fi

	echo "llama-router model reconcile: pruning cache for model $model"
	rm -rf -- "$cache_path"
	LLAMA_ROUTER_MODELS_CHANGED=1
}

prune_retired_model_caches() {
	local model

	while IFS= read -r model; do
		[ -n "$model" ] || continue
		prune_model_cache "$model"
	done <<<"$LLAMA_ROUTER_RETIRED_MODELS"
	return 0
}

# The router scans its cache once at startup; reloading its model view makes
# pruned entries disappear without restarting the router service (a restart
# would also unload every loaded model).
reload_router_view() {
	if ! curl -fsS "$LLAMA_ROUTER_URL/models?reload=1" >/dev/null 2>&1; then
		echo "llama-router model reconcile: failed to refresh router model view; ignoring because pruning already completed" >&2
	fi
}

load_main() {
	local wait_status=0

	init_vars

	if ! reconciliation_requested "$@"; then
		echo "llama-router model reconcile: no required or retired models configured"
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

	validate_cache_dir
	validate_required_models "$@"
	validate_retired_models "$@"
	unload_retired_models
	load_required_models "$@"
	prune_retired_model_caches
	if [ "$LLAMA_ROUTER_MODELS_CHANGED" -eq 1 ]; then
		reload_router_view
	fi
}

dispatch_load_worker() {
	local worker_unit poll_deadline active_state sub_state result
	worker_unit="$1"
	shift

	init_vars

	if ! reconciliation_requested "$@"; then
		echo "llama-router model reconcile: no required or retired models configured"
		return
	fi

	systemctl --user reset-failed "$worker_unit" >/dev/null 2>&1 || true
	systemctl --user start --no-block "$worker_unit"

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
		activating:* | active:*)
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
