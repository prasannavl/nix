#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	kanidm_metadata="${KANIDM_DECLARATIVE_METADATA-}"
	kanidm_url="${KANIDM_URL-}"
	kanidm_name="${KANIDM_NAME-}"
	kanidm_system_name="${KANIDM_SYSTEM_NAME-}"
	kanidm_container="${KANIDM_CONTAINER-}"
	kanidm_config_path="${KANIDM_CONFIG_PATH-}"
	kanidm_default_url=""
	kanidm_default_name=""
	kanidm_default_system_name=""
	kanidm_default_container=""
	kanidm_default_config_path="/data/server.toml"
}

require_env() {
	local name value
	name="$1"
	value="${!name-}"
	if [ -z "$value" ]; then
		printf '%s\n' "missing required environment variable: $name" >&2
		exit 1
	fi
}

load_metadata() {
	require_env KANIDM_DECLARATIVE_METADATA
	kanidm_default_url="$(jq -r '.url' "$kanidm_metadata")"
	kanidm_default_name="$(jq -r '.adminName' "$kanidm_metadata")"
	kanidm_default_system_name="$(jq -r '.systemAdminName // "admin"' "$kanidm_metadata")"
	kanidm_default_container="$(jq -r '.containerName // "kanidm_kanidm_1"' "$kanidm_metadata")"
	: "${kanidm_url:=$kanidm_default_url}"
	: "${kanidm_name:=$kanidm_default_name}"
	: "${kanidm_system_name:=$kanidm_default_system_name}"
	: "${kanidm_container:=$kanidm_default_container}"
	: "${kanidm_config_path:=$kanidm_default_config_path}"
}

kanidm_cmd_as() {
	local name
	name="$1"
	shift
	timeout --kill-after=5s 60s kanidm -H "$kanidm_url" -D "$name" "$@"
}

kanidm_cmd() {
	kanidm_cmd_as "$kanidm_name" "$@"
}

kanidm_json_cmd() {
	KANIDM_OUTPUT=json kanidm_cmd "$@"
}

kanidm_domain() {
	local host
	if [ -n "${KANIDM_DOMAIN-}" ]; then
		printf '%s\n' "$KANIDM_DOMAIN"
		return
	fi
	host="${kanidm_url#*://}"
	host="${host%%/*}"
	host="${host%%:*}"
	printf '%s\n' "$host"
}

log_run_as() {
	local name
	name="$1"
	shift
	printf '+ KANIDM_NAME=%q kanidm' "$name"
	printf ' %q' "$@"
	printf '\n'
}

log_run() {
	log_run_as "$kanidm_name" "$@"
}

run_as() {
	local name
	name="$1"
	shift
	log_run_as "$name" "$@"
	kanidm_cmd_as "$name" "$@" || exit "$?"
}

run() {
	log_run "$@"
	kanidm_cmd "$@" || exit "$?"
}

exec_in_container() {
	local -a exec_args
	exec_args=(exec)
	if [ -t 0 ]; then
		exec_args+=(-i)
	fi
	if [ -t 1 ]; then
		exec_args+=(-t)
	fi
	exec_args+=("$kanidm_container" "$@")

	printf '+ podman'
	printf ' %q' "${exec_args[@]}"
	printf '\n'
	podman "${exec_args[@]}"
}

recover_account() {
	local account
	account="$1"
	run_admin recover-account --config-path "$kanidm_config_path" "$account"
}

run_admin() {
	exec_in_container kanidmd "$@"
}

get() {
	kanidm_cmd "$@" >/dev/null 2>&1
}

json_entry_has_name() {
	local name object
	name="$1"
	object="$2"
	jq -e --arg name "$name" '
		type == "object" and (((.attrs.name // []) | index($name)) != null)
	' <<<"$object" >/dev/null
}

get_named_entry() {
	local name live
	name="$1"
	shift
	if ! live="$(kanidm_json_cmd "$@" "$name")"; then
		printf 'Kanidm read failed: %s %s\n' "$*" "$name" >&2
		exit 1
	fi
	if json_entry_has_name "$name" "$live"; then
		return 0
	fi
	if [[ "$live" == 'No matching entries' ]] ||
		jq -e 'type == "string" and startswith("No matching")' <<<"$live" >/dev/null 2>&1; then
		return 1
	fi
	printf 'Unexpected Kanidm entry response: %s %s\n' "$*" "$name" >&2
	exit 1
}

get_person() {
	local name
	name="$1"
	get_named_entry "$name" person get
}

get_group() {
	local name
	name="$1"
	get_named_entry "$name" group get
}

get_oauth_app() {
	get_named_entry "$1" system oauth2 get
}

oauth_app_type_matches() {
	local name desired_type live desired_public
	name="$1"
	desired_type="$2"
	live="$(kanidm_json_cmd system oauth2 get "$name")" || exit 1
	json_entry_has_name "$name" "$live" || exit 1

	if [ "$desired_type" = public ]; then
		desired_public=true
	else
		desired_public=false
	fi

	jq -e --argjson desired_public "$desired_public" '
		((.attrs.class // []) | index("oauth2_resource_server_public") != null) == $desired_public
	' <<<"$live" >/dev/null
}

get_service_account() {
	get_named_entry "$1" service-account get
}

group_member_name() {
	local member
	member="$1"
	printf '%s\n' "${member%@*}"
}

token_cache_path() {
	local path
	path="${KANIDM_TOKEN_CACHE_PATH:-~/.cache/kanidm_tokens}"
	case "$path" in
	~/*)
		printf '%s/%s\n' "${HOME:?HOME is required to expand token cache path}" "${path#"~/"}"
		;;
	*)
		printf '%s\n' "$path"
		;;
	esac
}

kanidm_bearer_token() {
	local domain instance path token
	domain="$(kanidm_domain)"
	instance="${KANIDM_INSTANCE-}"
	path="$(token_cache_path)"

	if [ ! -r "$path" ]; then
		printf 'Kanidm token cache is not readable: %s\n' "$path" >&2
		printf 'Run: %s login-idm-admin\n' "$0" >&2
		exit 1
	fi

	token="$(
		jq -r \
			--arg instance "$instance" \
			--arg name "$kanidm_name" \
			--arg spn "$kanidm_name@$domain" '
				.instances[$instance].tokens as $tokens
				| if ($tokens | type) != "object" then
					empty
				  else
					(
						$tokens[$spn]
						// $tokens[$name]
						// (
							$tokens
							| to_entries
							| map(select(.key | startswith($name + "@")))
							| if length == 1 then .[0].value else empty end
						)
					)
				  end
			' "$path"
	)"

	if [ -z "$token" ] || [ "$token" = null ]; then
		printf 'No usable Kanidm token found for %s in %s.\n' "$kanidm_name" "$path" >&2
		printf 'Run: %s login-idm-admin\n' "$0" >&2
		exit 1
	fi

	printf '%s\n' "$token"
}

curl_common_args() {
	printf '%s\0' --fail-with-body --silent --show-error --connect-timeout 5 --max-time 30
	if [ "${KANIDM_ACCEPT_INVALID_CERTS-}" = true ]; then
		printf '%s\0' --insecure
	fi
}

scim_request() {
	local method path body token response status
	local -a curl_args
	method="$1"
	path="$2"
	body="${3-}"
	token="$(kanidm_bearer_token)" || return 1
	mapfile -d '' -t curl_args < <(curl_common_args)
	curl_args+=(--request "$method" --header "Authorization: Bearer $token" --write-out $'\n%{http_code}')
	if [ -n "$body" ]; then
		curl_args+=(--header "Content-Type: application/json" --data "$body")
	fi
	if response="$(curl "${curl_args[@]}" "$kanidm_url$path")"; then
		status="${response##*$'\n'}"
		if [[ "$status" == 2[0-9][0-9] ]]; then
			printf '%s\n' "${response%$'\n'*}"
			return 0
		fi
	else
		status="${response##*$'\n'}"
	fi
	if [ "${KANIDM_ALLOW_NOT_FOUND-}" = true ] && [ "$status" = 404 ]; then
		printf 'null\n'
		return 0
	fi
	printf 'Kanidm HTTP %s %s failed (status %s)\n' "$method" "$path" "$status" >&2
	return 1
}

scim_get_application() {
	scim_request GET "/scim/v1/Application/$1"
}

scim_list_applications() {
	scim_request GET "/scim/v1/Application"
}

put_service_account_attr() {
	local service_account_id attr value body
	service_account_id="$1"
	attr="$2"
	value="$3"
	body="$(jq -cn --arg value "$value" '[$value]')"
	scim_request PUT "/v1/service_account/$service_account_id/_attr/$attr" "$body" >/dev/null
}

get_application() {
	local live
	live="$(KANIDM_ALLOW_NOT_FOUND=true scim_get_application "$1")" || exit 1
	if jq -e --arg name "$1" 'type == "object" and .name == $name' <<<"$live" >/dev/null; then return 0; fi
	if [ "$live" = null ]; then return 1; fi
	printf 'Unexpected Kanidm SCIM application response: %s\n' "$1" >&2
	exit 1
}

require_login() {
	require_login_as "$kanidm_name" "login-idm-admin"
}

require_login_as() {
	local name login_command
	name="$1"
	login_command="$2"
	if ! kanidm_cmd_as "$name" self whoami >/dev/null 2>&1; then
		printf 'No active Kanidm CLI session for %s at %s.\n' "$name" "$kanidm_url" >&2
		printf 'Run: %s %s\n' "$0" "$login_command" >&2
		exit 1
	fi
}

jq_state() {
	jq -c "$1" "$kanidm_metadata"
}

jq_state_raw() {
	jq -r "$1" "$kanidm_metadata"
}

jq_value() {
	jq -r "$1" <<<"$2"
}

state_name() {
	jq -r '.name // "kanidm-apply"' "$kanidm_metadata"
}

state_dir() {
	local base
	base="${KANIDM_DECLARATIVE_STATE_DIR-}"
	if [ -z "$base" ]; then
		base="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/kanidm-declarative"
	fi
	printf '%s\n' "$base"
}

managed_people_file() {
	printf '%s/%s.people' "$(state_dir)" "$(state_name)"
}

managed_groups_file() {
	printf '%s/%s.groups' "$(state_dir)" "$(state_name)"
}

managed_group_members_file() {
	printf '%s/%s.group-members' "$(state_dir)" "$(state_name)"
}

managed_ssh_public_keys_file() {
	printf '%s/%s.ssh-public-keys' "$(state_dir)" "$(state_name)"
}

auto_apply_stamp_dir() {
	printf '%s/auto-apply' "$(state_dir)"
}

auto_apply_stamp_file() {
	local account_name command key
	command="$1"
	account_name="$2"
	key="$(
		{
			printf '%s\0' "$(state_name)" "$command" "$account_name"
		} | sha256sum | cut -d' ' -f1
	)"
	printf '%s/%s.stamp' "$(auto_apply_stamp_dir)" "$key"
}

auto_apply_stamp_metadata() {
	local command icon_name icon_path
	command="$1"

	case "$command" in
	apply-system)
		jq -c '{contract: (.contract // {}), state: {domain: (.state.domain // {})}}' "$kanidm_metadata"
		;;
	*)
		jq -c 'del(.state.oauthApps[]?.iconPath)' "$kanidm_metadata"
		jq -r '
			.state.oauthApps[]?
			| select(.iconPath != null and .iconPath != "")
			| [.name, .iconPath]
			| @tsv
		' "$kanidm_metadata" |
			LC_ALL=C sort |
			while IFS=$'\t' read -r icon_name icon_path; do
				printf '%s\0%s\0' "$icon_name" "$(sha256sum "$icon_path" | cut -d' ' -f1)"
			done
		;;
	esac
}

auto_apply_desired_stamp() {
	local account_name command stamp_contract
	command="$1"
	account_name="$2"
	stamp_contract="${KANIDM_AUTO_APPLY_STAMP_CONTRACT:-kanidm-auto-apply-v1}"
	{
		printf '%s\0' "$stamp_contract"
		printf '%s\0' "$command" "$account_name" "$kanidm_url" "$(kanidm_domain)"
		auto_apply_stamp_metadata "$command"
	} | sha256sum | cut -d' ' -f1
}

auto_apply_stamp_matches() {
	local stamp_file desired_stamp current_stamp
	stamp_file="$1"
	desired_stamp="$2"

	[ -r "$stamp_file" ] || return 1
	current_stamp="$(cat "$stamp_file")"
	[ "$current_stamp" = "$desired_stamp" ]
}

record_auto_apply_stamp() {
	local stamp_file desired_stamp tmp_file
	stamp_file="$1"
	desired_stamp="$2"

	install -d -m 0700 "$(dirname "$stamp_file")"
	tmp_file="$(mktemp "${stamp_file}.tmp.XXXXXX")"
	printf '%s\n' "$desired_stamp" >"$tmp_file"
	mv "$tmp_file" "$stamp_file"
}

prune_missing_users_enabled() {
	[ "$(jq_state '.state.pruneUsers // false')" = true ]
}

prune_missing_groups_enabled() {
	[ "$(jq_state '.state.pruneGroups // false')" = true ]
}

prune_group_members_enabled() {
	[ "$(jq_state '.state.pruneGroupMembers // false')" = true ]
}

prune_missing_service_accounts_enabled() {
	[ "$(jq_state '.state.pruneServiceAccounts // false')" = true ]
}

prune_missing_scim_apps_enabled() {
	[ "$(jq_state '.state.pruneScimApps // false')" = true ]
}

prune_missing_oauth_apps_enabled() {
	[ "$(jq_state '.state.pruneOauthApps // false')" = true ]
}

prune_oauth_redirect_urls_enabled() {
	[ "$(jq_state '.state.pruneOauthRedirectUrls // false')" = true ]
}

prune_oauth_scope_maps_enabled() {
	[ "$(jq_state '.state.pruneOauthScopeMaps // false')" = true ]
}

prune_ssh_public_keys_enabled() {
	[ "$(jq_state '.state.pruneSshPublicKeys // false')" = true ]
}

declared_person_ids() {
	jq_state_raw '.state.users[]?.accountId' | LC_ALL=C sort -u
}

declared_group_ids() {
	jq_state_raw '.state.groups[]?.name' | LC_ALL=C sort -u
}

declared_group_member_keys() {
	# shellcheck disable=SC2016
	jq_state_raw '
		.state.groupMembers[]?
		| .name as $name
		| .members[]?
		| [$name, (split("@")[0])]
		| @tsv
	' | LC_ALL=C sort -u
}

declared_ssh_public_key_keys() {
	{
		# shellcheck disable=SC2016
		jq_state_raw '
			.state.users[]?
			| .accountId as $account_id
			| .sshPublicKeys
			| keys[]?
			| ["person", $account_id, .]
			| @tsv
		'
		# shellcheck disable=SC2016
		jq_state_raw '
			.state.serviceAccounts[]?
			| .accountId as $account_id
			| .sshPublicKeys
			| keys[]?
			| ["service-account", $account_id, .]
			| @tsv
		'
	} | LC_ALL=C sort -u
}

declared_service_account_ids() {
	jq_state_raw '.state.serviceAccounts[]?.accountId' | LC_ALL=C sort -u
}

declared_scim_app_ids() {
	jq_state_raw '.state.scimApps[]?.name' | LC_ALL=C sort -u
}

declared_oauth_app_ids() {
	jq_state_raw '.state.oauthApps[]?.name' | LC_ALL=C sort -u
}

is_declared_person() {
	local account_id
	account_id="$1"
	jq -e --arg account_id "$account_id" 'any(.state.users[]?; .accountId == $account_id)' "$kanidm_metadata" >/dev/null
}

is_declared_group() {
	local name
	name="$1"
	jq -e --arg name "$name" 'any(.state.groups[]?; .name == $name)' "$kanidm_metadata" >/dev/null
}

is_declared_service_account() {
	local account_id
	account_id="$1"
	jq -e --arg account_id "$account_id" 'any(.state.serviceAccounts[]?; .accountId == $account_id)' "$kanidm_metadata" >/dev/null
}

is_declared_scim_app() {
	local name
	name="$1"
	jq -e --arg name "$name" 'any(.state.scimApps[]?; .name == $name)' "$kanidm_metadata" >/dev/null
}

is_declared_oauth_app() {
	local name
	name="$1"
	jq -e --arg name "$name" 'any(.state.oauthApps[]?; .name == $name)' "$kanidm_metadata" >/dev/null
}

is_protected_service_account() {
	case "${1%%@*}" in
	anonymous | admin | idm_admin)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

live_service_account_ids() {
	scim_request GET "/v1/service_account" |
		jq -r 'if type == "array" then if all(.[]; type == "object" and (.attrs | type == "object" and all(.[]; type == "array" and all(.[]; type == "string"))) and (.attrs.name[0] | type == "string")) then .[] | select(((.attrs.class // []) | index("builtin")) == null) |
   select((.attrs.uuid // [] | any(. == "00000000-0000-0000-0000-000000000000" or . == "00000000-0000-0000-0000-000000000018" or . == "00000000-0000-0000-0000-ffffffffffff")) | not) |
   .attrs.name[0] else error("invalid service-account entry") end else error("invalid service-account collection") end' |
		LC_ALL=C sort -u
}

live_scim_app_ids() {
	scim_list_applications |
		jq -r 'if type == "object" and (.resources | type == "array") and all(.resources[]; .name | type == "string") then .resources[].name else error("invalid SCIM application collection") end' |
		LC_ALL=C sort -u
}

live_oauth_app_ids() {
	kanidm_json_cmd system oauth2 list |
		jq -r 'if type == "array" and all(.[]; .name[0] | type == "string") then .[].name[0] else error("invalid OAuth collection") end' |
		LC_ALL=C sort -u
}

prune_missing_people() {
	local state_file previous
	prune_missing_users_enabled || return 0

	state_file="$(managed_people_file)"
	install -d -m 0700 "$(dirname "$state_file")"

	if [ ! -e "$state_file" ]; then
		return 0
	fi

	while IFS= read -r previous; do
		[ -n "$previous" ] || continue
		is_protected_service_account "$previous" && continue
		if ! is_declared_person "$previous" && get_person "$previous"; then
			run person delete "$previous"
		fi
	done <"$state_file"
}

prune_missing_groups() {
	local state_file previous
	prune_missing_groups_enabled || return 0

	state_file="$(managed_groups_file)"
	install -d -m 0700 "$(dirname "$state_file")"

	if [ ! -e "$state_file" ]; then
		return 0
	fi

	while IFS= read -r previous; do
		[ -n "$previous" ] || continue
		if ! is_declared_group "$previous" && get_group "$previous"; then
			run group delete "$previous"
		fi
	done <"$state_file"
}

prune_group_members() {
	local state_file desired_keys previous group member
	prune_group_members_enabled || return 0

	state_file="$(managed_group_members_file)"
	install -d -m 0700 "$(dirname "$state_file")"

	if [ ! -e "$state_file" ]; then
		return 0
	fi

	desired_keys="$(
		declared_group_member_keys |
			jq -Rn '
				[inputs | select(. != "") | {key: ., value: true}]
				| from_entries
			'
	)"

	while IFS= read -r previous; do
		[ -n "$previous" ] || continue
		if jq -e --arg key "$previous" 'has($key)' <<<"$desired_keys" >/dev/null; then
			continue
		fi
		IFS=$'\t' read -r group member <<<"$previous"
		[ -n "$group" ] || continue
		[ -n "$member" ] || continue
		if get_group "$group"; then
			run group remove-members "$group" "$member"
		fi
	done <"$state_file"
}

prune_ssh_public_keys() {
	local state_file desired_keys previous kind account_id tag
	prune_ssh_public_keys_enabled || return 0

	state_file="$(managed_ssh_public_keys_file)"
	install -d -m 0700 "$(dirname "$state_file")"

	if [ ! -e "$state_file" ]; then
		return 0
	fi

	desired_keys="$(
		declared_ssh_public_key_keys |
			jq -Rn '
				[inputs | select(. != "") | {key: ., value: true}]
				| from_entries
			'
	)"

	while IFS= read -r previous; do
		[ -n "$previous" ] || continue
		if jq -e --arg key "$previous" 'has($key)' <<<"$desired_keys" >/dev/null; then
			continue
		fi
		IFS=$'\t' read -r kind account_id tag <<<"$previous"
		[ -n "$kind" ] || continue
		[ -n "$account_id" ] || continue
		is_protected_service_account "$account_id" && continue
		[ -n "$tag" ] || continue
		case "$kind" in
		person)
			if get_person "$account_id"; then
				run person ssh delete-publickey "$account_id" "$tag"
			fi
			;;
		service-account)
			if get_service_account "$account_id"; then
				run service-account ssh delete-publickey "$account_id" "$tag"
			fi
			;;
		esac
	done <"$state_file"
}

prune_missing_service_accounts() {
	local account_id live_ids
	prune_missing_service_accounts_enabled || return 0

	live_ids="$(live_service_account_ids)" || return 1
	while IFS= read -r account_id; do
		[ -n "$account_id" ] || continue
		if is_protected_service_account "$account_id"; then
			continue
		fi
		if ! is_declared_service_account "$account_id" && ! is_declared_scim_app "$account_id" && get_service_account "$account_id"; then
			run service-account delete "$account_id"
		fi
	done <<<"$live_ids"
}

prune_missing_scim_apps() {
	local name live_ids
	prune_missing_scim_apps_enabled || return 0

	live_ids="$(live_scim_app_ids)" || return 1
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		if ! is_declared_scim_app "$name" && get_application "$name"; then
			printf '+ scim app delete %q\n' "$name"
			scim_request DELETE "/scim/v1/Application/$name" >/dev/null || exit 1
		fi
	done <<<"$live_ids"
}

prune_missing_oauth_apps() {
	local name live_ids
	prune_missing_oauth_apps_enabled || return 0

	live_ids="$(live_oauth_app_ids)" || return 1
	while IFS= read -r name; do
		[ -n "$name" ] || continue
		if ! is_declared_oauth_app "$name" && get_oauth_app "$name"; then
			run system oauth2 delete "$name"
		fi
	done <<<"$live_ids"
}

remember_declared_people() {
	local state_file tmp_file

	state_file="$(managed_people_file)"
	install -d -m 0700 "$(dirname "$state_file")"
	tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
	declared_person_ids >"$tmp_file"
	mv "$tmp_file" "$state_file"
}

remember_declared_groups() {
	local state_file tmp_file

	state_file="$(managed_groups_file)"
	install -d -m 0700 "$(dirname "$state_file")"
	tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
	declared_group_ids >"$tmp_file"
	mv "$tmp_file" "$state_file"
}

remember_declared_group_members() {
	local state_file tmp_file

	state_file="$(managed_group_members_file)"
	install -d -m 0700 "$(dirname "$state_file")"
	tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
	declared_group_member_keys >"$tmp_file"
	mv "$tmp_file" "$state_file"
}

remember_declared_ssh_public_keys() {
	local state_file tmp_file

	state_file="$(managed_ssh_public_keys_file)"
	install -d -m 0700 "$(dirname "$state_file")"
	tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
	declared_ssh_public_key_keys >"$tmp_file"
	mv "$tmp_file" "$state_file"
}

verify_domain() {
	local desired live
	desired="$(jq_state_raw '.state.domain.displayName // empty')"
	[ -n "$desired" ] || return 0
	if ! live="$(kanidm_name="$kanidm_system_name" scim_request GET /v1/domain)"; then
		printf 'Kanidm domain verification read failed.\n' >&2
		return 2
	fi
	# /v1/domain returns Vec<ProtoEntry> in both 1.10.4 and 1.11.2.
	if ! jq -e '
  if type == "array" and length == 1 then .[0] |
   type == "object" and (.attrs | type == "object" and
    all(.[]; type == "array" and all(.[]; type == "string"))) and
   (.attrs.domain_display_name | type == "array")
  else false end
 ' <<<"$live" >/dev/null; then
		printf 'Kanidm domain verification expected one domain Entry with string attributes.\n' >&2
		return 2
	fi
	jq -e --arg desired "$desired" '.[0].attrs.domain_display_name == [$desired]' <<<"$live" >/dev/null
}

apply_domain() {
	local display_name
	display_name="$(jq_state_raw '.state.domain.displayName // empty')"
	if [ -n "$display_name" ]; then
		require_login_as "$kanidm_system_name" "login-system-admin"
		run_as "$kanidm_system_name" system domain set-displayname "$display_name"
		verify_domain || exit 1
	fi
}

apply_person() {
	local person account_id display_name legal_name posix_enable posix_shell posix_gid
	local -a update_args posix_args mail_args
	person="$1"
	account_id="$(jq_value '.accountId' "$person")"
	if is_protected_service_account "$account_id"; then
		printf 'Builtin Kanidm account %s is outside declarative account ownership.\n' "$account_id" >&2
		exit 1
	fi
	display_name="$(jq_value '.displayName' "$person")"
	legal_name="$(jq_value '.legalName // empty' "$person")"

	update_args=(--displayname "$display_name")
	if [ -n "$legal_name" ]; then
		update_args+=(--legalname "$legal_name")
	fi
	mail_args=()
	while IFS= read -r mail; do
		[ -n "$mail" ] || continue
		mail_args+=(--mail "$mail")
	done < <(jq -r '.mail[]?' <<<"$person")

	if get_person "$account_id"; then
		run person update "$account_id" "${update_args[@]}" "${mail_args[@]}"
	else
		run person create "$account_id" "$display_name"
		run person update "$account_id" "${update_args[@]}" "${mail_args[@]}"
	fi

	posix_enable="$(jq_value '.posix.enable // false' "$person")"
	if [ "$posix_enable" = true ]; then
		posix_args=()
		posix_shell="$(jq_value '.posix.shell // empty' "$person")"
		posix_gid="$(jq_value '.posix.gidNumber // empty' "$person")"
		if [ -n "$posix_shell" ]; then
			posix_args+=(--shell "$posix_shell")
		fi
		if [ -n "$posix_gid" ]; then
			posix_args+=(--gidnumber "$posix_gid")
		fi
		run person posix set "$account_id" "${posix_args[@]}"
	fi

	while IFS=$'\t' read -r tag public_key; do
		[ -n "$tag" ] || continue
		run person ssh delete-publickey "$account_id" "$tag"
		run person ssh add-publickey "$account_id" "$tag" "$public_key"
	done < <(jq -r '.sshPublicKeys | to_entries[]? | [.key, .value] | @tsv' <<<"$person")
}

apply_service_account() {
	local account service_account_id display_name entry_managed_by live read_rc tag public_key
	local -a update_args mail_args
	account="$1"
	service_account_id="$(jq_value '.accountId' "$account")"
	if is_protected_service_account "$service_account_id"; then
		printf 'Builtin Kanidm account %s is outside declarative account ownership.\n' "$service_account_id" >&2
		exit 1
	fi
	display_name="$(jq_value '.displayName' "$account")"
	entry_managed_by="$(jq_value '.entryManagedBy' "$account")"

	if live="$(read_verify_entry "$service_account_id" service-account get)"; then :; else
		read_rc="$?"
		if [ "$read_rc" -ne 1 ]; then
			printf 'Service account %s could not be read safely before applying.\n' "$service_account_id" >&2
			exit 2
		fi
		run service-account create "$service_account_id" "$display_name" "$entry_managed_by"
		live="$(read_verify_entry "$service_account_id" service-account get)" || exit 2
	fi

	# A PATCH requests permission for each supplied attribute even if its value
	# is unchanged. Manager reassignment has separate privileges from metadata.
	update_args=()
	if ! jq -e --arg expected "$display_name" '.attrs.displayname == [$expected]' <<<"$live" >/dev/null; then
		update_args+=(--displayname "$display_name")
	fi
	if ! jq -e --arg expected "$entry_managed_by" \
		'(.attrs.entry_managed_by // [] | map(split("@")[0])) == [($expected | split("@")[0])]' <<<"$live" >/dev/null; then
		update_args+=(--entry-managed-by "$entry_managed_by")
	fi
	mail_args=()
	if [ "$(jq '.mail | length' <<<"$account")" -gt 0 ] && ! jq -e --argjson desired "$account" '
  (.attrs.mail // []) as $actual | $desired.mail as $expected |
  ($actual[0] // null) == ($expected[0] // null) and
  ($actual[1:] | unique | sort) == ($expected[1:] | unique | sort)
 ' <<<"$live" >/dev/null; then
		while IFS= read -r mail; do
			mail_args+=(--mail "$mail")
		done < <(jq -r '.mail[]' <<<"$account")
	fi
	if [ "$((${#update_args[@]} + ${#mail_args[@]}))" -gt 0 ]; then
		run service-account update "$service_account_id" "${update_args[@]}" "${mail_args[@]}"
	fi

	while IFS=$'\t' read -r tag public_key; do
		[ -n "$tag" ] || continue
		if jq -e --arg tag "$tag" --arg key "$public_key" '
   def material: gsub("[[:space:]]+"; " ") | split(" ")[:2] | join(" ");
   any((.attrs.ssh_publickey // [])[];
    startswith($tag + ": ") and (sub("^[^:]+: "; "") | material) == ($key | material))
  ' <<<"$live" >/dev/null; then continue; fi
		run service-account ssh delete-publickey "$service_account_id" "$tag"
		run service-account ssh add-publickey "$service_account_id" "$tag" "$public_key"
	done < <(jq -r '.sshPublicKeys | to_entries[]? | [.key, .value] | @tsv' <<<"$account")
}

apply_group() {
	local group name description members_json mail_json mail
	local -a members mail_args
	group="$1"
	name="$(jq_value '.name' "$group")"
	description="$(jq_value '.description // empty' "$group")"
	members_json="$(jq -c '.members' <<<"$group")"
	mail_json="$(jq -c '.mail' <<<"$group")"

	if get_group "$name"; then
		if [ -n "$description" ]; then
			run group set-description "$name" "$description"
		fi
	else
		run group create "$name"
		if [ -n "$description" ]; then
			run group set-description "$name" "$description"
		fi
	fi

	if [ "$members_json" != null ]; then
		members=()
		while IFS= read -r member; do
			[ -n "$member" ] || continue
			members+=("$(group_member_name "$member")")
		done < <(jq -r '.members[]?' <<<"$group")
		if [ "${#members[@]}" -gt 0 ]; then
			run group set-members "$name" "${members[@]}"
		else
			run group purge-members "$name"
		fi
	fi

	if [ "$mail_json" != null ]; then
		mail_args=()
		while IFS= read -r mail; do
			[ -n "$mail" ] || continue
			mail_args+=("$mail")
		done < <(jq -r '.mail[]?' <<<"$group")
		run group set-mail "$name" "${mail_args[@]}"
	fi
}

apply_group_members() {
	local group name
	local -a members
	group="$1"
	name="$(jq_value '.name' "$group")"

	members=()
	while IFS= read -r member; do
		[ -n "$member" ] || continue
		members+=("$(group_member_name "$member")")
	done < <(jq -r '.members[]?' <<<"$group")

	if [ "${#members[@]}" -gt 0 ]; then
		run group add-members "$name" "${members[@]}"
	fi
}

apply_absent_group() {
	local group name
	group="$1"
	name="$(jq_value '.name' "$group")"

	if get_group "$name"; then
		run group delete "$name"
	fi
}

apply_scim_app() {
	local application name display_name linked_group body
	application="$1"
	name="$(jq_value '.name' "$application")"
	display_name="$(jq_value '.displayName' "$application")"
	linked_group="$(jq_value '.linkedGroup' "$application")"

	if get_application "$name"; then
		printf '+ scim app get %q\n' "$name"
	else
		printf '+ scim app create %q\n' "$name"
		body="$(
			jq -cn \
				--arg name "$name" \
				--arg display_name "$display_name" \
				--arg linked_group "$linked_group" \
				'{name: $name, displayname: $display_name, linked_group: [$linked_group]}'
		)"
		scim_request POST "/scim/v1/Application" "$body" >/dev/null || exit 1
	fi

	run service-account update "$name" --displayname "$display_name"
	printf '+ scim app set-linked-group %q %q\n' "$name" "$linked_group"
	put_service_account_attr "$name" linked_group "$linked_group"
}

normalize_oauth_client_urls() {
	# Rust url::Url and Node URL implement WHATWG serialization. Never replace
	# exact callback matching with origin-only comparison or strip path/query.
	node -e '
  const fs = require("node:fs");
  try {
   const client = JSON.parse(fs.readFileSync(0, "utf8"));
   const canonical = value => {
    if (typeof value !== "string") throw new Error("URL must be a string");
    return new URL(value).href;
   };
   client.origin = canonical(client.origin);
   client.landingUrl = canonical(client.landingUrl);
   client.redirectUrls = [...new Set((client.redirectUrls || []).map(canonical))];
   process.stdout.write(JSON.stringify(client));
  } catch (_) {
   process.stderr.write("Invalid Kanidm OAuth URL declaration.\n");
   process.exitCode = 1;
  }
 ' <<<"$1"
}

apply_oauth_app() {
	local client name display_name origin landing_url icon_path type create_command pkce
	local -a scopes
	client="$(normalize_oauth_client_urls "$1")" || exit 1
	name="$(jq_value '.name' "$client")"
	display_name="$(jq_value '.displayName' "$client")"
	origin="$(jq_value '.origin' "$client")"
	landing_url="$(jq_value '.landingUrl' "$client")"
	icon_path="$(jq -r '.iconPath // empty' <<<"$client")"
	type="$(jq_value '.type' "$client")"
	pkce="$(jq_value 'if has("pkce") then .pkce else true end' "$client")"

	if [ "$type" = public ]; then
		create_command="create-public"
	else
		create_command="create"
	fi

	if get_oauth_app "$name"; then
		if oauth_app_type_matches "$name" "$type"; then
			run system oauth2 set-displayname "$name" "$display_name"
			run system oauth2 set-landing-url "$name" "$landing_url"
		else
			printf 'OAuth client %s type differs; coordinate client credentials and grants before replacing it.\n' "$name" >&2
			exit 1
		fi
	else
		run system oauth2 "$create_command" "$name" "$display_name" "$origin"
		run system oauth2 set-landing-url "$name" "$landing_url"
	fi

	# Creation origin is a landing URL, not permission for an OAuth callback.

	while IFS= read -r redirect_url; do
		[ -n "$redirect_url" ] || continue
		run system oauth2 add-redirect-url "$name" "$redirect_url"
	done < <(jq -r '.redirectUrls[]?' <<<"$client")

	if [ "$pkce" = true ]; then
		run system oauth2 enable-pkce "$name"
	else
		run system oauth2 warning-insecure-client-disable-pkce "$name"
	fi

	if [ "$type" = public ]; then
		if [ "$(jq -r '.allowLocalhostRedirects // false' <<<"$client")" = true ]; then
			run system oauth2 enable-localhost-redirects "$name"
		else
			run system oauth2 disable-localhost-redirects "$name"
		fi
	fi

	while IFS=$'\t' read -r group scopes_json; do
		[ -n "$group" ] || continue
		mapfile -d '' -t scopes < <(jq -r '.[]' <<<"$scopes_json" | while IFS= read -r scope; do printf '%s\0' "$scope"; done)
		run system oauth2 update-scope-map "$name" "$group" "${scopes[@]}"
	done < <(jq -r '.scopeMaps | to_entries[]? | [.key, (.value | tojson)] | @tsv' <<<"$client")

	if [ -n "$icon_path" ]; then
		run system oauth2 set-image "$name" "$icon_path"
	fi

	prune_oauth_redirect_urls "$client"
	prune_oauth_scope_maps "$client"
}

prune_oauth_redirect_urls() {
	local client name live desired_urls redirect_url
	prune_oauth_redirect_urls_enabled || return 0

	client="$(normalize_oauth_client_urls "$1")" || exit 1
	name="$(jq_value '.name' "$client")"
	live="$(kanidm_json_cmd system oauth2 get "$name")"
	desired_urls="$(
		jq -c '
			(.redirectUrls // [])
			| map(select(. != null and . != ""))
			| map({key: ., value: true})
			| from_entries
		' <<<"$client"
	)"

	while IFS= read -r redirect_url; do
		[ -n "$redirect_url" ] || continue
		if jq -e --arg redirect_url "$redirect_url" 'has($redirect_url)' <<<"$desired_urls" >/dev/null; then
			continue
		fi
		run system oauth2 remove-redirect-url "$name" "$redirect_url"
	done < <(jq -r '(.attrs.oauth2_rs_origin // [])[]?' <<<"$live")
}

prune_oauth_scope_maps() {
	local client name live desired_groups domain group
	prune_oauth_scope_maps_enabled || return 0

	client="$1"
	name="$(jq_value '.name' "$client")"
	domain="$(kanidm_domain)"
	live="$(kanidm_json_cmd system oauth2 get "$name")"
	desired_groups="$(
		jq -c --arg domain "$domain" '
			(.scopeMaps // {})
			| keys
			| map(if contains("@") then . else . + "@" + $domain end)
			| map({key: ., value: true})
			| from_entries
		' <<<"$client"
	)"

	while IFS= read -r group; do
		[ -n "$group" ] || continue
		if jq -e --arg group "$group" 'has($group)' <<<"$desired_groups" >/dev/null; then
			continue
		fi
		run system oauth2 delete-scope-map "$name" "$group"
	done < <(jq -r '(.attrs.oauth2_rs_scope_map // [])[]? | split(":")[0]' <<<"$live")
}

verify_fail() {
	printf 'verify-idm: %s\n' "$*" >&2
	kanidm_verify_failed=1
	return 0
}

read_verify_entry() {
	local name live
	name="$1"
	shift
	if ! live="$(kanidm_json_cmd "$@" "$name")"; then return 2; fi
	if json_entry_has_name "$name" "$live" && jq -e '
  (.attrs | type == "object") and all(.attrs[]; type == "array" and all(.[]; type == "string"))
 ' <<<"$live" >/dev/null; then
		printf '%s\n' "$live"
		return 0
	fi
	if [[ "$live" == 'No matching entries' ]] || jq -e 'type == "string" and startswith("No matching")' <<<"$live" >/dev/null 2>&1; then return 1; fi
	return 2
}

verify_read_fail() {
	kanidm_verify_probe_failed=1
	verify_fail "$@"
}

verify_entry_contract() {
	local kind desired live errors error label
	kind="$1"
	desired="$2"
	live="$3"
	label="$(jq -r '.accountId // .name' <<<"$desired")"
	if ! errors="$(jq -c --arg kind "$kind" --argjson d "$desired" '
  def issue(ok; message): if ok then [] else [message] end;
  def short: split("@")[0];
  def mail_matches(actual; expected):
   (actual[0] // null) == (expected[0] // null) and
   (actual[1:] | unique | sort) == (expected[1:] | unique | sort);
  def key_material: gsub("[[:space:]]+"; " ") | split(" ")[:2] | join(" ");
  .attrs as $a |
  (if $kind == "person" or $kind == "service-account" then
   (if ($d.mail // [] | length) > 0 then issue(mail_matches(($a.mail // []); $d.mail); "mail differs") else [] end) +
   issue(($a.displayname // []) == [$d.displayName]; "display name differs") +
   (if $kind == "person" and $d.legalName != null then
    issue(($a.legalname // []) == [$d.legalName]; "legal name differs") else [] end) +
   (if $kind == "service-account" then
    issue(any(($a.entry_managed_by // [])[]; short == ($d.entryManagedBy | short)); "entry manager differs") else [] end) +
   (if $d.posix.enable // false then
    issue((($a.class // []) | index("posixaccount")) != null; "POSIX account missing") +
    (if $d.posix.shell != null then issue(($a.loginshell // []) == [$d.posix.shell]; "POSIX shell differs") else [] end) +
    (if $d.posix.gidNumber != null then issue(($a.gidnumber // []) == [($d.posix.gidNumber | tostring)]; "POSIX gid differs") else [] end)
    else [] end) +
   [($d.sshPublicKeys // {} | to_entries[]) as $key |
    select(any(($a.ssh_publickey // [])[];
     startswith($key.key + ": ") and
     (sub("^[^:]+: "; "") | key_material) == ($key.value | key_material)) | not) |
    "SSH public key differs: " + $key.key]
  elif $kind == "group" then
   (if $d.description != null then issue(($a.description // []) == [$d.description]; "description differs") else [] end) +
   (if $d.members != null then
    issue(([($a.member // [])[] | short] | sort) == ([$d.members[] | short] | unique | sort); "authoritative membership differs") else [] end) +
   (if $d.mail != null then
    issue(mail_matches(($a.mail // []); $d.mail); "group mail differs") else [] end)
  elif $kind == "oauth" then
   issue(((($a.class // []) | index("oauth2_resource_server_public")) != null) == ($d.type == "public"); "client type differs") +
   issue(($a.displayname // []) == [$d.displayName]; "display name differs") +
   issue(($a.oauth2_rs_origin_landing // []) == [$d.landingUrl]; "landing URL differs") +
   issue((($a.oauth2_allow_insecure_client_disable_pkce // ["false"])[0] == "true") == ($d.pkce | not); "PKCE policy differs")
  else error("unknown contract kind") end)
 ' <<<"$live")"; then
		verify_read_fail "$kind $label has an invalid live contract"
		return 0
	fi
	while IFS= read -r error; do
		verify_fail "$kind $label $error"
	done < <(jq -r '.[]' <<<"$errors")
}

verify_owned_pruning() {
	local previous group member live kind account_id tag ids
	if prune_missing_users_enabled && [ -f "$(managed_people_file)" ]; then
		while IFS= read -r previous; do
			[ -n "$previous" ] || continue
			is_protected_service_account "$previous" && continue
			if ! is_declared_person "$previous" && get_person "$previous"; then
				verify_fail "previously managed person $previous remains"
			fi
		done <"$(managed_people_file)"
	fi
	if prune_missing_groups_enabled && [ -f "$(managed_groups_file)" ]; then
		while IFS= read -r previous; do
			[ -n "$previous" ] || continue
			if ! is_declared_group "$previous" && get_group "$previous"; then
				verify_fail "previously managed group $previous remains"
			fi
		done <"$(managed_groups_file)"
	fi
	if prune_group_members_enabled && [ -f "$(managed_group_members_file)" ]; then
		while IFS=$'\t' read -r group member; do
			[ -n "$group" ] && [ -n "$member" ] || continue
			if jq -e --arg group "$group" --arg member "$member" '
    any(.state.groupMembers[]?; .name == $group and any(.members[]?; split("@")[0] == $member))
   ' "$kanidm_metadata" >/dev/null; then continue; fi
			if live="$(read_verify_entry "$group" group get)"; then :; else
				[ "$?" -ne 1 ] || continue
				verify_read_fail "group $group read failed during owned-member verification"
				return 2
			fi
			if jq -e --arg member "$member" 'any((.attrs.member // [])[]; split("@")[0] == $member)' <<<"$live" >/dev/null; then
				verify_fail "previously managed member $group/$member remains"
			fi
		done <"$(managed_group_members_file)"
	fi
	if prune_ssh_public_keys_enabled && [ -f "$(managed_ssh_public_keys_file)" ]; then
		while IFS=$'\t' read -r kind account_id tag; do
			[ -n "$account_id" ] && [ -n "$tag" ] || continue
			is_protected_service_account "$account_id" && continue
			if jq -e --arg kind "$kind" --arg account "$account_id" --arg tag "$tag" '
    (if $kind == "person" then .state.users else .state.serviceAccounts end) |
    any(.[]?; .accountId == $account and (.sshPublicKeys | has($tag)))
   ' "$kanidm_metadata" >/dev/null; then continue; fi
			if live="$(read_verify_entry "$account_id" "$kind" get)"; then :; else
				[ "$?" -ne 1 ] || continue
				verify_read_fail "$kind $account_id read failed during owned-key verification"
				return 2
			fi
			if jq -e --arg prefix "$tag: " 'any((.attrs.ssh_publickey // [])[]; startswith($prefix))' <<<"$live" >/dev/null; then
				verify_fail "previously managed SSH key $account_id/$tag remains"
			fi
		done <"$(managed_ssh_public_keys_file)"
	fi
	if prune_missing_service_accounts_enabled; then
		if ids="$(live_service_account_ids)"; then
			while IFS= read -r account_id; do
				[ -n "$account_id" ] || continue
				if ! is_protected_service_account "$account_id" && ! is_declared_service_account "$account_id" && ! is_declared_scim_app "$account_id"; then
					verify_fail "unmanaged service account $account_id remains in owned namespace"
				fi
			done <<<"$ids"
		else
			verify_read_fail "service-account collection read failed"
			return 2
		fi
	fi
	if prune_missing_scim_apps_enabled; then
		if ids="$(live_scim_app_ids)"; then
			while IFS= read -r previous; do
				[ -n "$previous" ] || continue
				if ! is_declared_scim_app "$previous"; then verify_fail "unmanaged SCIM application $previous remains"; fi
			done <<<"$ids"
		else
			verify_read_fail "SCIM application collection read failed"
			return 2
		fi
	fi
	if prune_missing_oauth_apps_enabled; then
		if ids="$(live_oauth_app_ids)"; then
			while IFS= read -r previous; do
				[ -n "$previous" ] || continue
				if ! is_declared_oauth_app "$previous"; then verify_fail "unmanaged OAuth client $previous remains"; fi
			done <<<"$ids"
		else
			verify_read_fail "OAuth collection read failed"
			return 2
		fi
	fi
}

verify_person() {
	local person account_id live expected_mail primary_mail actual_primary_mail
	person="$1"
	account_id="$(jq_value '.accountId' "$person")"

	if live="$(read_verify_entry "$account_id" person get)"; then :; else
		if [ "$?" -eq 1 ]; then verify_fail "person get $account_id missing"; else verify_read_fail "person get $account_id read failed or invalid response"; fi
		return 0
	fi
	verify_entry_contract person "$person" "$live"

	primary_mail="$(jq -r '.mail[0] // empty' <<<"$person")"
	if [ -n "$primary_mail" ]; then
		actual_primary_mail="$(jq -r '.attrs.mail[0] // empty' <<<"$live")"
		if [ "$actual_primary_mail" != "$primary_mail" ]; then
			verify_fail "person $account_id primary mail is '$actual_primary_mail', expected '$primary_mail'"
		fi
	fi

	while IFS= read -r expected_mail; do
		[ -n "$expected_mail" ] || continue
		if ! jq -e --arg mail "$expected_mail" '(.attrs.mail // []) | index($mail) != null' <<<"$live" >/dev/null; then
			verify_fail "person $account_id missing mail '$expected_mail'"
		fi
	done < <(jq -r '.mail[]?' <<<"$person")
}

verify_group() {
	local group name member live domain expected_member primary_mail actual_primary_mail expected_mail
	group="$1"
	name="$(jq_value '.name' "$group")"
	domain="$(kanidm_domain)"

	if live="$(read_verify_entry "$name" group get)"; then :; else
		if [ "$?" -eq 1 ]; then verify_fail "group get $name missing"; else verify_read_fail "group get $name read failed or invalid response"; fi
		return 0
	fi
	verify_entry_contract group "$group" "$live"

	primary_mail="$(jq -r '.mail[0] // empty' <<<"$group")"
	if [ -n "$primary_mail" ]; then
		actual_primary_mail="$(jq -r '.attrs.mail[0] // empty' <<<"$live")"
		if [ "$actual_primary_mail" != "$primary_mail" ]; then
			verify_fail "group $name primary mail is '$actual_primary_mail', expected '$primary_mail'"
		fi
	fi

	while IFS= read -r expected_mail; do
		[ -n "$expected_mail" ] || continue
		if ! jq -e --arg mail "$expected_mail" '(.attrs.mail // []) | index($mail) != null' <<<"$live" >/dev/null; then
			verify_fail "group $name missing mail '$expected_mail'"
		fi
	done < <(jq -r '.mail[]?' <<<"$group")

	while IFS= read -r member; do
		[ -n "$member" ] || continue
		if [[ "$member" == *@* ]]; then
			expected_member="$member"
		else
			expected_member="$member@$domain"
		fi
		if ! jq -e --arg member "$expected_member" '(.attrs.member // []) | index($member) != null' <<<"$live" >/dev/null; then
			verify_fail "group $name missing member '$expected_member'"
		fi
	done < <(jq -r '.members[]?' <<<"$group")
}

verify_group_members() {
	local group name member live domain expected_member
	group="$1"
	name="$(jq_value '.name' "$group")"
	domain="$(kanidm_domain)"

	if live="$(read_verify_entry "$name" group get)"; then :; else
		if [ "$?" -eq 1 ]; then verify_fail "group get $name missing"; else verify_read_fail "group get $name read failed or invalid response"; fi
		return 0
	fi

	while IFS= read -r member; do
		[ -n "$member" ] || continue
		if [[ "$member" == *@* ]]; then
			expected_member="$member"
		else
			expected_member="$member@$domain"
		fi
		if ! jq -e --arg member "$expected_member" '(.attrs.member // []) | index($member) != null' <<<"$live" >/dev/null; then
			verify_fail "group $name missing managed member '$expected_member'"
		fi
	done < <(jq -r '.members[]?' <<<"$group")
}

verify_absent_group() {
	local group name
	group="$1"
	name="$(jq_value '.name' "$group")"

	if get_group "$name"; then
		verify_fail "group $name should be absent"
	fi
}

verify_scim_app() {
	local application name display_name linked_group live domain
	application="$1"
	name="$(jq_value '.name' "$application")"
	display_name="$(jq_value '.displayName' "$application")"
	linked_group="$(jq_value '.linkedGroup' "$application")"
	domain="$(kanidm_domain)"

	if ! live="$(KANIDM_ALLOW_NOT_FOUND=true scim_get_application "$name")"; then
		verify_read_fail "application $name read failed"
		return 0
	fi
	if [ "$live" = null ]; then
		verify_fail "application $name missing"
		return 0
	fi
	if ! jq -e 'type == "object" and (.name | type == "string") and (.displayname | type == "string") and (.linked_group | type == "array") and all(.linked_group[]; .value | type == "string")' <<<"$live" >/dev/null; then
		verify_read_fail "application $name has an invalid response"
		return 0
	fi
	if ! jq -e --arg name "$name" '.name == $name' <<<"$live" >/dev/null; then
		verify_fail "application $name name mismatch"
	fi
	if ! jq -e --arg display_name "$display_name" '.displayname == $display_name' <<<"$live" >/dev/null; then
		verify_fail "application $name display name mismatch"
	fi
	if ! jq -e --arg linked_group "$linked_group" --arg group_spn "$linked_group@$domain" '[.linked_group[].value | split("@")[0]] == [($linked_group | split("@")[0])]' <<<"$live" >/dev/null; then
		verify_fail "application $name missing linked group '$linked_group'"
	fi
}

# Exact 1.10/1.11 Entry image serialization: SHA256(filename || enum byte || payload).
# Keep this representation in the versioned contract fixture when upgrading Kanidm.
oauth_image_fingerprint() {
	local path filename image_type
	path="$1"
	filename="${path##*/}"
	case "${filename##*.}" in
	png) image_type='\000' ;;
	jpg | jpeg) image_type='\001' ;;
	gif) image_type='\002' ;;
	svg) image_type='\003' ;;
	webp) image_type='\004' ;;
	*) return 1 ;;
	esac
	{
		printf '%s' "$filename"
		printf '%b' "$image_type"
		cat "$path"
	} | sha256sum | cut -d' ' -f1
}

verify_oauth_app() {
	local client name icon_path icon_hash group scopes_json live domain group_spn scope_map scope_values redirect_url desired_urls desired_groups live_group
	if ! client="$(normalize_oauth_client_urls "$1")"; then
		verify_read_fail "OAuth declaration has an invalid URL"
		return 0
	fi
	name="$(jq_value '.name' "$client")"
	icon_path="$(jq -r '.iconPath // empty' <<<"$client")"
	domain="$(kanidm_domain)"

	if live="$(read_verify_entry "$name" system oauth2 get)"; then :; else
		if [ "$?" -eq 1 ]; then verify_fail "system oauth2 get $name missing"; else verify_read_fail "system oauth2 get $name read failed or invalid response"; fi
		return 0
	fi
	verify_entry_contract oauth "$client" "$live"
	if ! jq -e 'type == "object" and (.attrs | type == "object")' <<<"$live" >/dev/null; then
		verify_fail "oauth app $name missing"
		return 0
	fi

	if ! jq -e --argjson expected "$(jq '.allowLocalhostRedirects // false' <<<"$client")" \
		'((.attrs.oauth2_allow_localhost_redirect // ["false"]) == [($expected | tostring)])' \
		<<<"$live" >/dev/null; then
		verify_fail "oauth app $name localhost redirect setting differs"
	fi

	if [ -n "$icon_path" ]; then
		if icon_hash="$(oauth_image_fingerprint "$icon_path")"; then
			if ! jq -e --arg expected "$icon_hash" '(.attrs.image // []) == [$expected]' <<<"$live" >/dev/null; then
				verify_fail "oauth app $name image differs"
			fi
		else verify_read_fail "oauth app $name desired image cannot be fingerprinted"; fi
	fi

	while IFS= read -r redirect_url; do
		[ -n "$redirect_url" ] || continue
		if ! jq -e --arg redirect_url "$redirect_url" '(.attrs.oauth2_rs_origin // []) | index($redirect_url) != null' <<<"$live" >/dev/null; then
			verify_fail "oauth app $name missing redirect URL '$redirect_url'"
		fi
	done < <(jq -r '.redirectUrls[]?' <<<"$client")

	if prune_oauth_redirect_urls_enabled; then
		desired_urls="$(
			jq -c '
				(.redirectUrls // [])
				| map(select(. != null and . != ""))
				| map({key: ., value: true})
				| from_entries
			' <<<"$client"
		)"
		while IFS= read -r redirect_url; do
			[ -n "$redirect_url" ] || continue
			if ! jq -e --arg redirect_url "$redirect_url" 'has($redirect_url)' <<<"$desired_urls" >/dev/null; then
				verify_fail "oauth app $name has unmanaged redirect URL '$redirect_url'"
			fi
		done < <(jq -r '(.attrs.oauth2_rs_origin // [])[]?' <<<"$live")
	fi

	while IFS=$'\t' read -r group scopes_json; do
		[ -n "$group" ] || continue
		if [[ "$group" == *@* ]]; then
			group_spn="$group"
		else
			group_spn="$group@$domain"
		fi
		scope_map="$(jq -r --arg prefix "$group_spn: " '(.attrs.oauth2_rs_scope_map // [])[] | select(startswith($prefix))' <<<"$live")"
		if [ -z "$scope_map" ]; then
			verify_fail "oauth app $name missing scope map for '$group_spn'"
			continue
		fi
		if ! scope_values="$(jq -c '
   sub("^[^:]+: "; "") | sub("^\\{"; "[") | sub("\\}$"; "]") | fromjson |
   if type == "array" and all(.[]; type == "string") then sort else error("invalid scope representation") end
  ' <<<"$(jq -Rn --arg text "$scope_map" '$text')")"; then
			verify_read_fail "oauth app $name scope map representation is invalid"
		elif ! jq -e --argjson expected "$scopes_json" '. == ($expected | unique | sort)' <<<"$scope_values" >/dev/null; then
			verify_fail "oauth app $name scope values differ for '$group_spn'"
		fi
	done < <(jq -r '.scopeMaps | to_entries[]? | [.key, (.value | tojson)] | @tsv' <<<"$client")

	if prune_oauth_scope_maps_enabled; then
		desired_groups="$(
			jq -c --arg domain "$domain" '
				(.scopeMaps // {})
				| keys
				| map(if contains("@") then . else . + "@" + $domain end)
				| map({key: ., value: true})
				| from_entries
			' <<<"$client"
		)"
		while IFS= read -r live_group; do
			[ -n "$live_group" ] || continue
			if ! jq -e --arg group "$live_group" 'has($group)' <<<"$desired_groups" >/dev/null; then
				verify_fail "oauth app $name has unmanaged scope map for '$live_group'"
			fi
		done < <(jq -r '(.attrs.oauth2_rs_scope_map // [])[]? | split(":")[0]' <<<"$live")
	fi
}

verify_idm() {
	local item
	if ! jq -e '
  (.state | type == "object") and
  all([.state.users // [], .state.serviceAccounts // [], .state.groups // [],
       .state.groupMembers // [], .state.absentGroups // [], .state.scimApps // [],
       .state.oauthApps // []][]; type == "array" and all(.[]; type == "object")) and
  all([.state.users // [], .state.serviceAccounts // []][] | .[];
   (.accountId | split("@")[0]) as $name | $name != "anonymous" and $name != "admin" and $name != "idm_admin") and
  all(.state | to_entries[] | select(.key | startswith("prune")); .value | type == "boolean")
 ' "$kanidm_metadata" >/dev/null; then
		printf 'Kanidm verification metadata is invalid.\n' >&2
		return 2
	fi
	require_login
	kanidm_verify_failed=0
	kanidm_verify_probe_failed=0

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_person "$item"
		[ "$kanidm_verify_probe_failed" -eq 0 ] || return 2
	done < <(jq_state '.state.users[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_service_account "$item"
		[ "$kanidm_verify_probe_failed" -eq 0 ] || return 2
	done < <(jq_state '.state.serviceAccounts[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_group "$item"
		[ "$kanidm_verify_probe_failed" -eq 0 ] || return 2
	done < <(jq_state '.state.groups[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_group_members "$item"
		[ "$kanidm_verify_probe_failed" -eq 0 ] || return 2
	done < <(jq_state '.state.groupMembers[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_absent_group "$item"
		[ "$kanidm_verify_probe_failed" -eq 0 ] || return 2
	done < <(jq_state '.state.absentGroups[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_scim_app "$item"
		[ "$kanidm_verify_probe_failed" -eq 0 ] || return 2
	done < <(jq_state '.state.scimApps[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_oauth_app "$item"
		[ "$kanidm_verify_probe_failed" -eq 0 ] || return 2
	done < <(jq_state '.state.oauthApps[]?')

	verify_owned_pruning
	[ "$kanidm_verify_probe_failed" -eq 0 ] || return 2
	[ "$kanidm_verify_failed" -eq 0 ]
}

verify_service_account() {
	local account service_account_id live expected_mail primary_mail actual_primary_mail
	account="$1"
	service_account_id="$(jq_value '.accountId' "$account")"

	if live="$(read_verify_entry "$service_account_id" service-account get)"; then :; else
		if [ "$?" -eq 1 ]; then verify_fail "service-account get $service_account_id missing"; else verify_read_fail "service-account get $service_account_id read failed or invalid response"; fi
		return 0
	fi
	verify_entry_contract service-account "$account" "$live"

	primary_mail="$(jq -r '.mail[0] // empty' <<<"$account")"
	if [ -n "$primary_mail" ]; then
		actual_primary_mail="$(jq -r '.attrs.mail[0] // empty' <<<"$live")"
		if [ "$actual_primary_mail" != "$primary_mail" ]; then
			verify_fail "service account $service_account_id primary mail is '$actual_primary_mail', expected '$primary_mail'"
		fi
	fi

	while IFS= read -r expected_mail; do
		[ -n "$expected_mail" ] || continue
		if ! jq -e --arg mail "$expected_mail" '(.attrs.mail // []) | index($mail) != null' <<<"$live" >/dev/null; then
			verify_fail "service account $service_account_id missing mail '$expected_mail'"
		fi
	done < <(jq -r '.mail[]?' <<<"$account")
}

apply_all() {
	apply_domain
	apply_idm
}

apply_idm() {
	local item
	require_login

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		apply_absent_group "$item"
	done < <(jq_state '.state.absentGroups[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		apply_person "$item"
	done < <(jq_state '.state.users[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		apply_service_account "$item"
	done < <(jq_state '.state.serviceAccounts[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		apply_group "$item"
	done < <(jq_state '.state.groups[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		apply_scim_app "$item"
	done < <(jq_state '.state.scimApps[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		apply_group_members "$item"
	done < <(jq_state '.state.groupMembers[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		apply_oauth_app "$item"
	done < <(jq_state '.state.oauthApps[]?')

	prune_missing_service_accounts
	prune_missing_scim_apps
	prune_missing_oauth_apps
	prune_missing_people
	prune_missing_groups
	prune_group_members
	prune_ssh_public_keys
	verify_idm || return "$?"
	remember_declared_people
	remember_declared_groups
	remember_declared_group_members
	remember_declared_ssh_public_keys
}

curl_status_args() {
	printf '%s\0' --fail --silent --show-error
	if [ "${KANIDM_ACCEPT_INVALID_CERTS-}" = true ]; then
		printf '%s\0' --insecure
	fi
}

wait_for_kanidm_status() {
	local wait_seconds deadline remaining request_seconds
	local -a curl_args
	wait_seconds="${KANIDM_AUTO_APPLY_WAIT_SECONDS:-60}"
	if [[ ! "$wait_seconds" =~ ^[1-9][0-9]*$ ]]; then
		printf 'KANIDM_AUTO_APPLY_WAIT_SECONDS must be a positive integer, got: %s\n' "$wait_seconds" >&2
		return 1
	fi
	deadline=$((SECONDS + wait_seconds))
	mapfile -d '' -t curl_args < <(curl_status_args)
	while [ "$SECONDS" -lt "$deadline" ]; do
		remaining=$((deadline - SECONDS))
		request_seconds="$remaining"
		[ "$request_seconds" -le 10 ] || request_seconds=10
		if curl "${curl_args[@]}" --connect-timeout "$request_seconds" --max-time "$request_seconds" "$kanidm_url/status" >/dev/null; then
			return 0
		fi
		[ "$SECONDS" -ge "$deadline" ] || sleep 1
	done
	printf 'Kanidm status was not ready within %s seconds.\n' "$wait_seconds" >&2
	return 1
}

auto_apply_idm() {
	local account_name command desired_stamp login_started_epoch login_output login_rc password_file stamp_file stamp_matches verify_rc
	command="${KANIDM_AUTO_APPLY_COMMAND:-apply-idm}"
	password_file="${KANIDM_AUTO_APPLY_PASSWORD_FILE-}"

	case "$command" in
	apply-idm)
		account_name="$kanidm_name"
		;;
	apply-system)
		account_name="$kanidm_system_name"
		;;
	*)
		printf 'unsupported Kanidm auto-apply command: %s\n' "$command" >&2
		exit 2
		;;
	esac

	require_env KANIDM_AUTO_APPLY_PASSWORD_FILE
	if [ ! -s "$password_file" ]; then
		printf 'Kanidm auto-apply password file is missing or empty: %s\n' "$password_file" >&2
		exit 1
	fi

	desired_stamp="$(auto_apply_desired_stamp "$command" "$account_name")"
	stamp_file="$(auto_apply_stamp_file "$command" "$account_name")"
	stamp_matches=false
	if auto_apply_stamp_matches "$stamp_file" "$desired_stamp"; then stamp_matches=true; fi
	kanidm_auto_apply_token_dir="$(mktemp -d)"
	trap 'rm -rf "$kanidm_auto_apply_token_dir"' EXIT
	export KANIDM_TOKEN_CACHE_PATH="$kanidm_auto_apply_token_dir/tokens.json"

	wait_for_kanidm_status
	login_started_epoch="$(date +%s)"
	login_output="$(mktemp)"
	set +e
	KANIDM_PASSWORD="$(tr -d '\n' <"$password_file")" kanidm_cmd_as "$account_name" login >"$login_output" 2>&1
	login_rc="$?"
	set -e
	if [ "$login_rc" -eq 0 ]; then
		rm -f "$login_output"
		case "$command" in
		apply-idm)
			if [ "$stamp_matches" = true ]; then
				if verify_idm; then
					printf 'Kanidm owned IdM state verified; skipping unchanged writes.\n'
					return 0
				else
					verify_rc="$?"
					[ "$verify_rc" -eq 1 ] || return "$verify_rc"
				fi
			fi
			apply_idm
			;;
		apply-system)
			if [ "$stamp_matches" = true ]; then
				if verify_domain; then
					printf 'Kanidm owned domain state verified; skipping unchanged writes.\n'
					return 0
				else
					verify_rc="$?"
					[ "$verify_rc" -eq 1 ] || return "$verify_rc"
				fi
			fi
			apply_domain
			;;
		esac
		record_auto_apply_stamp "$stamp_file" "$desired_stamp"
		return
	fi

	if journalctl -b --since "@$login_started_epoch" --no-pager -o cat 2>/dev/null |
		grep -F "Initiating Authentication Session | username: $account_name |" >/dev/null &&
		journalctl -b --since "@$login_started_epoch" --no-pager -o cat 2>/dev/null |
		grep -F "account has no available credentials" >/dev/null; then
		printf 'Kanidm account %s is not bootstrapped; cannot run %s with the declared password.\n' \
			"$account_name" "$command" >&2
		printf '%s\n' "Recover the account, update the matching age secret, and redeploy before starting dependent OIDC services." >&2
		rm -f "$login_output"
		exit 1
	fi

	printf 'Kanidm auto-apply login failed for %s; refusing to skip.\n' "$account_name" >&2
	printf '%s\n' "This does not look like an unbootstrapped account." >&2
	cat "$login_output" >&2
	rm -f "$login_output"
	exit "$login_rc"
}

usage() {
	cat <<USAGE
Usage: $(basename "$0") <command>

Commands:
  login-idm-admin             Log in as $kanidm_name for IdM state commands.
  login-system-admin          Log in as $kanidm_system_name for system/domain settings.
  apply                       Apply declared system/domain settings and IdM state.
  apply-system                Apply declared system/domain settings.
  apply-idm                   Apply declared people, service accounts, groups, ScimApps, and OAuthApps.
  auto-apply-idm              Log in from a password file and run the configured auto-apply command.
  cli <args...>               Run kanidm with the configured URL and account defaults.
  admin <args...>             Run kanidmd inside the Kanidm container.
  exec <args...>              Run a command inside the Kanidm container.
  recover-idm-admin           Recover credentials for $kanidm_name.
  recover-system-admin        Recover credentials for $kanidm_system_name.
  verify-idm                  Verify declared people, groups, ScimApps, OAuthApps redirect URLs, and scope maps.
  reset <account> [ttl]       Create a credential reset token for a person account.
  service-password <account>  Generate a service-account password.
  service-api-token <account> <label> [expiry]
                              Generate a service-account API token.
  oauth-secret <client>       Show the basic secret for a confidential OAuthApp.

Environment:
  KANIDM_URL          Defaults to $kanidm_default_url
  KANIDM_NAME         Defaults to $kanidm_default_name
  KANIDM_SYSTEM_NAME  Defaults to $kanidm_default_system_name
  KANIDM_CONTAINER    Defaults to $kanidm_default_container
USAGE
}

main() {
	local command
	init_vars
	load_metadata

	command="${1:-apply}"
	shift || true

	case "$command" in
	login-idm-admin)
		run login
		;;
	login-system-admin)
		run_as "$kanidm_system_name" login
		;;
	apply)
		apply_all
		;;
	apply-system)
		apply_domain
		;;
	apply-idm)
		apply_idm
		;;
	auto-apply-idm)
		auto_apply_idm
		;;
	cli)
		run "$@"
		;;
	admin)
		run_admin "$@"
		;;
	exec)
		exec_in_container "$@"
		;;
	recover-idm-admin)
		recover_account "$kanidm_name"
		;;
	recover-system-admin)
		recover_account "$kanidm_system_name"
		;;
	verify-idm)
		verify_idm
		;;
	reset)
		require_login
		run person credential create-reset-token "$@"
		;;
	service-password)
		require_login
		run service-account credential generate "$@"
		;;
	service-api-token)
		require_login
		run service-account api-token generate "$@"
		;;
	oauth-secret)
		require_login
		run system oauth2 show-basic-secret "$@"
		;;
	-h | --help | help)
		usage
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
}
