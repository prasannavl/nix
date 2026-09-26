#!/usr/bin/env bash

: "${plan:?missing AI model-prefetch plan path}"
: "${cache_preparer:=}"

# shellcheck disable=SC2016
readonly MODEL_PREFETCH_SCHEMA='
def nonempty_string:
  type == "string" and length > 0;
def safe_path:
  nonempty_string
  and test("^/[A-Za-z0-9._+,:=@-]+(/[A-Za-z0-9._+,:=@-]+)*$")
  and (test("/(\\.\\.?)(/|$)") | not);
def only_keys($allowed):
  ((keys_unsorted - $allowed) | length) == 0;
def valid_owner:
  type == "object"
  and only_keys(["name", "uid", "group", "gid"])
  and (.name | nonempty_string)
  and (.uid | type == "number" and isfinite and floor == . and . >= 0 and . <= 2147483647)
  and (.group | nonempty_string)
  and (.gid | type == "number" and isfinite and floor == . and . >= 0 and . <= 2147483647);
def valid_identity:
  (
    (has("owner") and (.owner | valid_owner))
    or ((has("owner") | not) and (.user | nonempty_string))
  )
  and ((has("user") | not) or (.user | nonempty_string))
  and (if has("owner") and has("user") then .user == .owner.name else true end);
def valid_common:
  type == "object"
  and (.id | nonempty_string)
  and (.model | nonempty_string)
  and valid_identity;
def valid_hf:
  valid_common
  and only_keys(["id", "type", "model", "revision", "include", "cacheDir", "tokenFile", "user", "owner", "policy"])
  and .type == "hf"
  and .policy == "required"
  and ((.revision == null) or (.revision | nonempty_string))
  and (.include | type == "array" and all(.[]; nonempty_string))
  and (.cacheDir | safe_path)
  and ((.tokenFile == null) or (.tokenFile | safe_path));
def valid_api:
  valid_common
  and only_keys(["id", "type", "model", "endpoints", "user", "owner", "policy"])
  and (.type == "ollama" or .type == "llama")
  and .policy == "best-effort"
  and (
    .endpoints
    | type == "array"
      and length > 0
      and all(.[]; nonempty_string and test("^https?://[^[:space:]]+$"))
  );
def valid_entry:
  valid_hf or valid_api;
'

model_log() {
	printf '%s\n' "ai-model-prefetch-all: $*" >&2
}

positive_integer() {
	[[ "$1" =~ ^[1-9][0-9]*$ ]]
}

validate_runtime_settings() {
	: "${AI_MODEL_PREFETCH_BEST_EFFORT_SECONDS:=300}"
	: "${AI_MODEL_PREFETCH_HTTP_CONNECT_SECONDS:=5}"
	: "${AI_MODEL_PREFETCH_HF_TIMEOUT_SECONDS:=21600}"

	if ! positive_integer "${AI_MODEL_PREFETCH_BEST_EFFORT_SECONDS}" ||
		! positive_integer "${AI_MODEL_PREFETCH_HTTP_CONNECT_SECONDS}" ||
		! positive_integer "${AI_MODEL_PREFETCH_HF_TIMEOUT_SECONDS}"; then
		model_log "prefetch timeout settings must be positive integer seconds"
		return 1
	fi
	export AI_MODEL_PREFETCH_BEST_EFFORT_SECONDS
	export AI_MODEL_PREFETCH_HTTP_CONNECT_SECONDS
	export AI_MODEL_PREFETCH_HF_TIMEOUT_SECONDS
}

validate_plan() {
	if [[ ! -f "${plan}" ]]; then
		model_log "plan does not exist: ${plan}"
		return 1
	fi
	if ! jq -e "${MODEL_PREFETCH_SCHEMA}
		type == \"array\"
		and all(.[]; valid_entry)
		and (([.[].id] | length) == ([.[].id] | unique | length))" \
		"${plan}" >/dev/null; then
		model_log "model-prefetch plan is malformed or violates its schema: ${plan}"
		return 1
	fi
}

validate_entry() {
	local entry="$1"
	jq -e "${MODEL_PREFETCH_SCHEMA} valid_entry" <<<"${entry}" >/dev/null
}

entry_value() {
	local entry="$1" query="$2"
	jq -er "${query}" <<<"${entry}"
}

ensure_best_effort_deadline() {
	local now
	if [[ -n "${AI_MODEL_PREFETCH_BEST_EFFORT_DEADLINE_EPOCH:-}" ]]; then
		positive_integer "${AI_MODEL_PREFETCH_BEST_EFFORT_DEADLINE_EPOCH}"
		return
	fi
	now="$(date +%s)"
	AI_MODEL_PREFETCH_BEST_EFFORT_DEADLINE_EPOCH=$((now + AI_MODEL_PREFETCH_BEST_EFFORT_SECONDS))
	export AI_MODEL_PREFETCH_BEST_EFFORT_DEADLINE_EPOCH
}

ensure_hf_deadline() {
	local now
	if [[ -n "${AI_MODEL_PREFETCH_HF_DEADLINE_EPOCH:-}" ]]; then
		positive_integer "${AI_MODEL_PREFETCH_HF_DEADLINE_EPOCH}"
		return
	fi
	now="$(date +%s)"
	AI_MODEL_PREFETCH_HF_DEADLINE_EPOCH=$((now + AI_MODEL_PREFETCH_HF_TIMEOUT_SECONDS))
	export AI_MODEL_PREFETCH_HF_DEADLINE_EPOCH
}

remaining_best_effort_seconds() {
	local now remaining
	if ! positive_integer "${AI_MODEL_PREFETCH_BEST_EFFORT_DEADLINE_EPOCH:-}"; then
		return 1
	fi
	now="$(date +%s)"
	remaining=$((AI_MODEL_PREFETCH_BEST_EFFORT_DEADLINE_EPOCH - now))
	((remaining > 0)) || return 1
	printf '%s\n' "${remaining}"
}

remaining_hf_seconds() {
	local now remaining
	if ! positive_integer "${AI_MODEL_PREFETCH_HF_DEADLINE_EPOCH:-}"; then
		return 1
	fi
	now="$(date +%s)"
	remaining=$((AI_MODEL_PREFETCH_HF_DEADLINE_EPOCH - now))
	((remaining > 0)) || return 1
	printf '%s\n' "${remaining}"
}

best_effort_curl() {
	local remaining connect_timeout
	remaining="$(remaining_best_effort_seconds)" || return 1
	connect_timeout="${AI_MODEL_PREFETCH_HTTP_CONNECT_SECONDS}"
	if ((connect_timeout > remaining)); then
		connect_timeout="${remaining}"
	fi
	timeout --foreground --signal=TERM --kill-after=1s "${remaining}s" \
		curl --connect-timeout "${connect_timeout}" --max-time "${remaining}" "$@"
}

read_huggingface_token() {
	local token_file="$1"
	local -a token_lines=()

	if [[ ! -r "${token_file}" ]]; then
		model_log "Hugging Face token file is unreadable: ${token_file}"
		return 1
	fi
	if ! mapfile -t token_lines <"${token_file}" ||
		[[ "${#token_lines[@]}" -ne 1 || ! "${token_lines[0]}" =~ ^[^[:space:]]+$ ]]; then
		model_log "Hugging Face token file must contain exactly one non-empty whitespace-free line"
		return 1
	fi
	printf '%s\n' "${token_lines[0]}"
}

validate_huggingface_token() {
	local entry="$1" token_file
	token_file="$(entry_value "${entry}" '.tokenFile // ""')"
	[[ -z "${token_file}" ]] || read_huggingface_token "${token_file}" >/dev/null
}

acquire_huggingface() {
	local entry="$1" model revision cache_dir token_file token="" include include_count index remaining
	local -a args

	model="$(entry_value "${entry}" '.model')"
	revision="$(entry_value "${entry}" '.revision // ""')"
	cache_dir="$(entry_value "${entry}" '.cacheDir')"
	token_file="$(entry_value "${entry}" '.tokenFile // ""')"

	if [[ -n "${token_file}" ]]; then
		token="$(read_huggingface_token "${token_file}")" || return 1
	fi
	export HF_HOME="${cache_dir}"
	args=(download "${model}")
	if [[ -n "${revision}" ]]; then
		args+=(--revision "${revision}")
	fi
	include_count="$(entry_value "${entry}" '.include | length')"
	for ((index = 0; index < include_count; index += 1)); do
		include="$(entry_value "${entry}" ".include[${index}]")"
		args+=(--include "${include}")
	done
	remaining="$(remaining_hf_seconds)" || return 1
	if ! (
		unset HF_TOKEN HUGGING_FACE_HUB_TOKEN || true
		if [[ -n "${token_file}" ]]; then
			export HF_TOKEN="${token}"
		fi
		timeout --foreground --signal=TERM --kill-after=1s \
			"${remaining}s" hf "${args[@]}" >/dev/null
	); then
		return 1
	fi
	model_log "cached Hugging Face model ${model}${revision:+ at ${revision}}"
}

acquire_ollama() {
	local entry="$1" model request endpoint response endpoint_count index
	model="$(entry_value "${entry}" '.model')"
	request="$(jq -cn --arg name "${model}" '{name: $name, stream: false}')"
	endpoint_count="$(entry_value "${entry}" '.endpoints | length')"

	for ((index = 0; index < endpoint_count; index += 1)); do
		endpoint="$(entry_value "${entry}" ".endpoints[${index}]")"
		if response="$(best_effort_curl --fail --silent --show-error \
			--header 'Content-Type: application/json' \
			--data-binary "${request}" \
			"${endpoint%/}/api/pull")" &&
			jq -e 'type == "object" and .status == "success"' <<<"${response}" >/dev/null; then
			model_log "cached Ollama model ${model} through ${endpoint}"
			return 0
		fi
	done
	model_log "no running Ollama endpoint could cache ${model}"
	return 1
}

llama_status() {
	local endpoint="$1" model="$2" response status
	if ! response="$(best_effort_curl --fail --silent --show-error \
		"${endpoint%/}/models" 2>/dev/null)"; then
		printf 'unreachable\n'
		return 0
	fi
	if ! status="$(jq -er --arg model "${model}" '
		if type != "object" or (.data | type) != "array" then
		  error("invalid llama.cpp models response")
		else
		  ([.data[] | select(.id == $model)] | first // null) as $entry
		  | if $entry == null then "absent"
		    elif ($entry.id | type) != "string"
		      or ($entry.status | type) != "object"
		      or ($entry.status.value | type) != "string"
		      or (($entry.status.failed // false) | type) != "boolean" then
		      error("invalid llama.cpp model status")
		    elif ($entry.status.failed // false) then "failed"
		    else $entry.status.value end
		end' <<<"${response}")"; then
		printf 'unknown\n'
		return 0
	fi
	printf '%s\n' "${status}"
}

acquire_llama_at() {
	local endpoint="$1" model="$2" status payload response
	status="$(llama_status "${endpoint}" "${model}")"
	case "${status}" in
	unloaded | loaded | sleeping | downloading | downloaded | loading)
		return 0
		;;
	absent)
		payload="$(jq -cn --arg model "${model}" '{model: $model}')"
		if ! response="$(best_effort_curl --fail --silent --show-error \
			--request POST \
			--header 'Content-Type: application/json' \
			--data-binary "${payload}" \
			"${endpoint%/}/models")"; then
			return 1
		fi
		if ! jq -e 'type == "object" and ((.error? // null) == null)' <<<"${response}" >/dev/null; then
			model_log "llama.cpp endpoint rejected the request or returned malformed JSON: ${endpoint}"
			return 1
		fi
		# Preactivation reports only requests explicitly accepted by the current
		# endpoint. The post-activation reconciler separately verifies eventual
		# state and remains the convergence authority.
		return 0
		;;
	*)
		return 1
		;;
	esac
}

acquire_llama() {
	local entry="$1" model endpoint endpoint_count index
	model="$(entry_value "${entry}" '.model')"
	endpoint_count="$(entry_value "${entry}" '.endpoints | length')"
	for ((index = 0; index < endpoint_count; index += 1)); do
		endpoint="$(entry_value "${entry}" ".endpoints[${index}]")"
		if acquire_llama_at "${endpoint}" "${model}"; then
			model_log "cached llama.cpp model ${model} through ${endpoint}"
			return 0
		fi
	done
	model_log "no running llama.cpp endpoint could cache ${model}"
	return 1
}

acquire_entry() {
	local entry="$1" type
	type="$(entry_value "${entry}" '.type')"
	case "${type}" in
	hf) acquire_huggingface "${entry}" ;;
	ollama) acquire_ollama "${entry}" ;;
	llama) acquire_llama "${entry}" ;;
	*) return 1 ;;
	esac
}

passwd_fields() {
	local record="$1" name _password uid gid _rest
	record="${record%%$'\n'*}"
	IFS=: read -r name _password uid gid _rest <<<"${record}"
	[[ -n "${name}" && "${uid}" =~ ^[0-9]+$ && "${gid}" =~ ^[0-9]+$ ]] || return 1
	printf '%s\t%s\t%s\n' "${name}" "${uid}" "${gid}"
}

group_fields() {
	local record="$1" name _password gid _members
	record="${record%%$'\n'*}"
	IFS=: read -r name _password gid _members <<<"${record}"
	[[ -n "${name}" && "${gid}" =~ ^[0-9]+$ ]] || return 1
	printf '%s\t%s\n' "${name}" "${gid}"
}

entry_owner() {
	local entry="$1" user record fields name uid gid group
	if jq -e 'has("owner")' <<<"${entry}" >/dev/null; then
		jq -er '[.owner.name, (.owner.uid | tostring), .owner.group, (.owner.gid | tostring)] | @tsv' <<<"${entry}"
		return
	fi
	user="$(entry_value "${entry}" '.user')"
	if ! record="$(getent passwd "${user}" 2>/dev/null)"; then
		model_log "model cache owner does not exist: ${user}"
		return 1
	fi
	fields="$(passwd_fields "${record}")" || return 1
	IFS=$'\t' read -r name uid gid <<<"${fields}"
	if ! record="$(getent group "${gid}" 2>/dev/null)"; then
		model_log "model cache owner group does not exist: ${gid}"
		return 1
	fi
	fields="$(group_fields "${record}")" || return 1
	IFS=$'\t' read -r group gid <<<"${fields}"
	printf '%s\t%s\t%s\t%s\n' "${name}" "${uid}" "${group}" "${gid}"
}

validate_owner_conflicts() {
	local name="$1" uid="$2" group="$3" gid="$4" record fields found_name found_uid found_group found_gid
	if record="$(getent passwd "${name}" 2>/dev/null)"; then
		fields="$(passwd_fields "${record}")" || return 1
		IFS=$'\t' read -r found_name found_uid found_gid <<<"${fields}"
		if [[ "${found_name}" != "${name}" || "${found_uid}" != "${uid}" || "${found_gid}" != "${gid}" ]]; then
			model_log "candidate owner conflicts with current passwd entry: ${name}"
			return 1
		fi
	fi
	if record="$(getent passwd "${uid}" 2>/dev/null)"; then
		fields="$(passwd_fields "${record}")" || return 1
		IFS=$'\t' read -r found_name found_uid found_gid <<<"${fields}"
		if [[ "${found_name}" != "${name}" || "${found_uid}" != "${uid}" || "${found_gid}" != "${gid}" ]]; then
			model_log "candidate owner UID conflicts with current passwd entry: ${uid}"
			return 1
		fi
	fi
	if record="$(getent group "${group}" 2>/dev/null)"; then
		fields="$(group_fields "${record}")" || return 1
		IFS=$'\t' read -r found_group found_gid <<<"${fields}"
		if [[ "${found_group}" != "${group}" || "${found_gid}" != "${gid}" ]]; then
			model_log "candidate owner group conflicts with current group entry: ${group}"
			return 1
		fi
	fi
	if record="$(getent group "${gid}" 2>/dev/null)"; then
		fields="$(group_fields "${record}")" || return 1
		IFS=$'\t' read -r found_group found_gid <<<"${fields}"
		if [[ "${found_group}" != "${group}" || "${found_gid}" != "${gid}" ]]; then
			model_log "candidate owner GID conflicts with current group entry: ${gid}"
			return 1
		fi
	fi
}

prepare_cache_leaf() {
	local entry="$1" uid="$2" gid="$3" cache_dir
	cache_dir="$(entry_value "${entry}" '.cacheDir')"
	if [[ -z "${cache_preparer}" || ! -f "${cache_preparer}" ]]; then
		model_log "candidate cache preparer is unavailable: ${cache_preparer:-<unset>}"
		return 1
	fi
	python3 "${cache_preparer}" "${cache_dir}" "${uid}" "${gid}"
}

validate_run_identity() {
	local entry="$1" owner_fields name uid group gid current_uid current_gid
	owner_fields="$(entry_owner "${entry}")" || return 1
	IFS=$'\t' read -r name uid group gid <<<"${owner_fields}"
	validate_owner_conflicts "${name}" "${uid}" "${group}" "${gid}" || return 1
	current_uid="$(id -u)"
	current_gid="$(id -g)"
	if [[ "${current_uid}" != 0 && ("${current_uid}" != "${uid}" || "${current_gid}" != "${gid}") ]]; then
		model_log "must run as root or numeric model cache owner ${name} (${uid}:${gid})"
		return 1
	fi
}

validate_token_as_owner() {
	local entry="$1" token_file owner_fields name uid group gid current_uid current_gid
	token_file="$(entry_value "${entry}" '.tokenFile // ""')"
	[[ -n "${token_file}" ]] || return 0
	owner_fields="$(entry_owner "${entry}")" || return 1
	IFS=$'\t' read -r name uid group gid <<<"${owner_fields}"
	current_uid="$(id -u)"
	current_gid="$(id -g)"
	if [[ "${current_uid}" == "${uid}" && "${current_gid}" == "${gid}" ]]; then
		validate_huggingface_token "${entry}"
	else
		setpriv --reuid="${uid}" --regid="${gid}" --clear-groups --no-new-privs -- \
			env HOME=/ USER="${name}" LOGNAME="${name}" "$0" validate-token "${entry}"
	fi
}

validate_required_prerequisites() {
	local count index entry
	count="$(jq -er 'length' "${plan}")"
	for ((index = 0; index < count; index += 1)); do
		entry="$(jq -cer --argjson index "${index}" '.[$index]' "${plan}")" || return 1
		if [[ "$(entry_value "${entry}" '.policy')" == "required" ]]; then
			validate_run_identity "${entry}" || return 1
			validate_token_as_owner "${entry}" || return 1
		fi
	done
}

run_entry_as_owner() {
	local entry="$1" owner_fields name uid group gid current_uid current_gid type cache_dir
	owner_fields="$(entry_owner "${entry}")" || return 1
	IFS=$'\t' read -r name uid group gid <<<"${owner_fields}"
	validate_run_identity "${entry}" || return 1
	current_uid="$(id -u)"
	current_gid="$(id -g)"
	type="$(entry_value "${entry}" '.type')"
	if [[ "${type}" == "hf" ]]; then
		prepare_cache_leaf "${entry}" "${uid}" "${gid}" || return 1
	fi
	if [[ "${current_uid}" == "${uid}" && "${current_gid}" == "${gid}" ]]; then
		acquire_entry "${entry}"
	elif [[ "${type}" == "hf" ]]; then
		cache_dir="$(entry_value "${entry}" '.cacheDir')"
		setpriv --reuid="${uid}" --regid="${gid}" --clear-groups --no-new-privs -- \
			env HOME="${cache_dir}" HF_HOME="${cache_dir}" USER="${name}" LOGNAME="${name}" \
			"$0" acquire "${entry}"
	else
		setpriv --reuid="${uid}" --regid="${gid}" --clear-groups --no-new-privs -- \
			env HOME=/ USER="${name}" LOGNAME="${name}" "$0" acquire "${entry}"
	fi
}

run_plan() {
	local entry policy id count failures=0 index
	validate_plan || return 1
	validate_required_prerequisites || return 1
	count="$(jq -er 'length' "${plan}")"
	for ((index = 0; index < count; index += 1)); do
		if ! entry="$(jq -cer --argjson index "${index}" '.[$index]' "${plan}")"; then
			model_log "could not read validated model-prefetch entry ${index}"
			return 1
		fi
		policy="$(entry_value "${entry}" '.policy')"
		id="$(entry_value "${entry}" '.id')"
		if [[ "${policy}" == "best-effort" ]]; then
			ensure_best_effort_deadline || return 1
		else
			ensure_hf_deadline || return 1
		fi
		if run_entry_as_owner "${entry}"; then
			continue
		fi
		if [[ "${policy}" == "best-effort" ]]; then
			model_log "best-effort prefetch deferred for ${id}"
		else
			model_log "required prefetch failed for ${id}"
			((failures += 1))
		fi
	done
	model_log "processed ${count} model prefetch entries"
	((failures == 0))
}

main() {
	validate_runtime_settings || return 1
	case "${1:-run}" in
	run) run_plan ;;
	validate-token)
		shift
		if [[ "$#" -ne 1 ]] || ! validate_entry "$1" ||
			[[ "$(entry_value "$1" '.type')" != "hf" ]]; then
			model_log "validate-token requires one schema-valid Hugging Face entry"
			return 2
		fi
		validate_huggingface_token "$1"
		;;
	acquire)
		shift
		if [[ "$#" -ne 1 ]] || ! validate_entry "$1"; then
			model_log "acquire requires one schema-valid entry"
			return 2
		fi
		acquire_entry "$1"
		;;
	*)
		model_log "usage: $0 [run | acquire ENTRY_JSON | validate-token ENTRY_JSON]"
		return 2
		;;
	esac
}
