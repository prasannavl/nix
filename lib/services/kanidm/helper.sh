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
	kanidm -H "$kanidm_url" -D "$name" "$@"
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
	kanidm_cmd_as "$name" "$@"
}

run() {
	log_run "$@"
	kanidm_cmd "$@"
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
	live="$(kanidm_json_cmd "$@" "$name")" || return 1
	json_entry_has_name "$name" "$live"
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
	local name live
	name="$1"
	live="$(kanidm_json_cmd system oauth2 get "$name")"
	jq -e --arg name "$name" 'type == "object" and (((.attrs.name // []) | index($name)) != null)' <<<"$live" >/dev/null
}

oauth_app_type_matches() {
	local name desired_type live desired_public
	name="$1"
	desired_type="$2"
	live="$(kanidm_json_cmd system oauth2 get "$name")"

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
	local name live
	name="$1"
	live="$(kanidm_json_cmd service-account get "$name")"
	jq -e --arg name "$name" 'type == "object" and (((.attrs.name // []) | index($name)) != null)' <<<"$live" >/dev/null
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
	printf '%s\0' --fail-with-body --silent --show-error
	if [ "${KANIDM_ACCEPT_INVALID_CERTS-}" = true ]; then
		printf '%s\0' --insecure
	fi
}

scim_request() {
	local method path body token
	local -a curl_args
	method="$1"
	path="$2"
	body="${3-}"
	token="$(kanidm_bearer_token)"
	mapfile -d '' -t curl_args < <(curl_common_args)

	if [ -n "$body" ]; then
		curl "${curl_args[@]}" \
			--request "$method" \
			--header "Authorization: Bearer $token" \
			--header "Content-Type: application/json" \
			--data "$body" \
			"$kanidm_url$path"
	else
		curl "${curl_args[@]}" \
			--request "$method" \
			--header "Authorization: Bearer $token" \
			"$kanidm_url$path"
	fi
}

scim_get_application() {
	local name
	name="$1"
	scim_request GET "/scim/v1/Application/$name"
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
	local name
	name="$1"
	scim_get_application "$name" >/dev/null 2>&1
}

ignore_missing() {
	log_run "$@"
	kanidm_cmd "$@" >/dev/null 2>&1 || true
}

try_add() {
	log_run "$@"
	kanidm_cmd "$@" || true
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

auto_apply_desired_stamp() {
	local account_name command stamp_contract
	command="$1"
	account_name="$2"
	stamp_contract="${KANIDM_AUTO_APPLY_STAMP_CONTRACT:-kanidm-auto-apply-v1}"
	{
		printf '%s\0' "$stamp_contract"
		printf '%s\0' "$command" "$account_name" "$kanidm_url" "$(kanidm_domain)"
		cat "$kanidm_metadata"
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
	case "$1" in
	admin | idm_admin)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

live_service_account_ids() {
	kanidm_json_cmd service-account list |
		jq -r '
			def first_string(value):
				if (value | type) == "array" then
					value[0] // empty
				elif (value | type) == "string" then
					value
				else
					empty
				end;
			def account_id:
				(
					if (.attrs.name? != null) then
						first_string(.attrs.name)
					elif (.name? != null) then
						first_string(.name)
					else
						first_string(.spn)
					end
				)
				| split("@")[0];
			if type == "array" then
				.[] | account_id
			elif type == "object" and (.items? | type) == "array" then
				.items[] | account_id
			elif type == "object" and (.resources? | type) == "array" then
				.resources[] | account_id
			elif type == "object" then
				account_id
			else
				empty
			end
		' | LC_ALL=C sort -u
}

live_scim_app_ids() {
	scim_list_applications |
		jq -r '.resources[]?.name // empty' |
		LC_ALL=C sort -u
}

live_oauth_app_ids() {
	kanidm_json_cmd system oauth2 list |
		jq -r '
			def first_string(value):
				if (value | type) == "array" then
					value[0] // empty
				elif (value | type) == "string" then
					value
				else
					empty
				end;
			def client_id:
				(
					if (.attrs.name? != null) then
						first_string(.attrs.name)
					elif (.name? != null) then
						first_string(.name)
					else
						empty
					end
				)
				| split("@")[0];
			if type == "array" then
				.[] | client_id
			elif type == "object" and (.items? | type) == "array" then
				.items[] | client_id
			elif type == "object" and (.resources? | type) == "array" then
				.resources[] | client_id
			elif type == "object" then
				client_id
			else
				empty
			end
		' | LC_ALL=C sort -u
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
			ignore_missing group remove-members "$group" "$member"
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
		[ -n "$tag" ] || continue
		case "$kind" in
		person)
			if get_person "$account_id"; then
				ignore_missing person ssh delete-publickey "$account_id" "$tag"
			fi
			;;
		service-account)
			if get_service_account "$account_id"; then
				ignore_missing service-account ssh delete-publickey "$account_id" "$tag"
			fi
			;;
		esac
	done <"$state_file"
}

prune_missing_service_accounts() {
	local account_id
	prune_missing_service_accounts_enabled || return 0

	while IFS= read -r account_id; do
		[ -n "$account_id" ] || continue
		if is_protected_service_account "$account_id"; then
			continue
		fi
		if ! is_declared_service_account "$account_id" && get_service_account "$account_id"; then
			run service-account delete "$account_id"
		fi
	done < <(live_service_account_ids)
}

prune_missing_scim_apps() {
	local name
	prune_missing_scim_apps_enabled || return 0

	while IFS= read -r name; do
		[ -n "$name" ] || continue
		if ! is_declared_scim_app "$name" && get_application "$name"; then
			printf '+ scim app delete %q\n' "$name"
			scim_request DELETE "/scim/v1/Application/$name" >/dev/null
		fi
	done < <(live_scim_app_ids)
}

prune_missing_oauth_apps() {
	local name
	prune_missing_oauth_apps_enabled || return 0

	while IFS= read -r name; do
		[ -n "$name" ] || continue
		if ! is_declared_oauth_app "$name" && get_oauth_app "$name"; then
			run system oauth2 delete "$name"
		fi
	done < <(live_oauth_app_ids)
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

apply_domain() {
	local display_name
	display_name="$(jq_state_raw '.state.domain.displayName // empty')"
	if [ -n "$display_name" ]; then
		require_login_as "$kanidm_system_name" "login-system-admin"
		run_as "$kanidm_system_name" system domain set-displayname "$display_name"
	fi
}

apply_person() {
	local person account_id display_name legal_name posix_enable posix_shell posix_gid
	local -a update_args posix_args mail_args
	person="$1"
	account_id="$(jq_value '.accountId' "$person")"
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
		ignore_missing person ssh delete-publickey "$account_id" "$tag"
		run person ssh add-publickey "$account_id" "$tag" "$public_key"
	done < <(jq -r '.sshPublicKeys | to_entries[]? | [.key, .value] | @tsv' <<<"$person")
}

apply_service_account() {
	local account service_account_id display_name entry_managed_by
	local -a update_args mail_args
	account="$1"
	service_account_id="$(jq_value '.accountId' "$account")"
	display_name="$(jq_value '.displayName' "$account")"
	entry_managed_by="$(jq_value '.entryManagedBy' "$account")"

	update_args=(--displayname "$display_name")
	mail_args=()
	while IFS= read -r mail; do
		[ -n "$mail" ] || continue
		mail_args+=(--mail "$mail")
	done < <(jq -r '.mail[]?' <<<"$account")

	if get_service_account "$service_account_id"; then
		run service-account update "$service_account_id" "${update_args[@]}" "${mail_args[@]}"
	else
		run service-account create "$service_account_id" "$display_name" "$entry_managed_by"
		run service-account update "$service_account_id" "${update_args[@]}" "${mail_args[@]}"
	fi

	while IFS=$'\t' read -r tag public_key; do
		[ -n "$tag" ] || continue
		ignore_missing service-account ssh delete-publickey "$service_account_id" "$tag"
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
		try_add group add-members "$name" "${members[@]}"
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
		scim_request POST "/scim/v1/Application" "$body" >/dev/null
	fi

	run service-account update "$name" --displayname "$display_name"
	printf '+ scim app set-linked-group %q %q\n' "$name" "$linked_group"
	put_service_account_attr "$name" linked_group "$linked_group"
}

apply_oauth_app() {
	local client name display_name origin landing_url icon_path type create_command pkce
	local -a scopes
	client="$1"
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
			run system oauth2 delete "$name"
			run system oauth2 "$create_command" "$name" "$display_name" "$origin"
			run system oauth2 set-landing-url "$name" "$landing_url"
		fi
	else
		run system oauth2 "$create_command" "$name" "$display_name" "$origin"
		run system oauth2 set-landing-url "$name" "$landing_url"
	fi

	while IFS= read -r redirect_url; do
		[ -n "$redirect_url" ] || continue
		try_add system oauth2 add-redirect-url "$name" "$redirect_url"
	done < <(jq -r '.redirectUrls[]?' <<<"$client")

	if [ "$pkce" = true ]; then
		run system oauth2 enable-pkce "$name"
	else
		run system oauth2 warning-insecure-client-disable-pkce "$name"
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

	client="$1"
	name="$(jq_value '.name' "$client")"
	live="$(kanidm_json_cmd system oauth2 get "$name")"
	desired_urls="$(
		jq -c '
			([.origin] + (.redirectUrls // []))
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

verify_person() {
	local person account_id live expected_mail primary_mail actual_primary_mail
	person="$1"
	account_id="$(jq_value '.accountId' "$person")"

	live="$(kanidm_json_cmd person get "$account_id")"

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

	live="$(kanidm_json_cmd group get "$name")"

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

	live="$(kanidm_json_cmd group get "$name")"

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

	live="$(scim_get_application "$name")"
	if ! jq -e --arg name "$name" '.name == $name' <<<"$live" >/dev/null; then
		verify_fail "application $name name mismatch"
	fi
	if ! jq -e --arg display_name "$display_name" '.displayname == $display_name' <<<"$live" >/dev/null; then
		verify_fail "application $name display name mismatch"
	fi
	if ! jq -e --arg linked_group "$linked_group" --arg group_spn "$linked_group@$domain" '(.linked_group // []) | any(.value == $linked_group or .value == $group_spn)' <<<"$live" >/dev/null; then
		verify_fail "application $name missing linked group '$linked_group'"
	fi
}

verify_oauth_app() {
	local client name icon_path group scopes_json live domain group_spn scope_map scope redirect_url desired_urls desired_groups live_group
	client="$1"
	name="$(jq_value '.name' "$client")"
	icon_path="$(jq -r '.iconPath // empty' <<<"$client")"
	domain="$(kanidm_domain)"

	live="$(kanidm_json_cmd system oauth2 get "$name")"
	if ! jq -e 'type == "object" and (.attrs | type == "object")' <<<"$live" >/dev/null; then
		verify_fail "oauth app $name missing"
		return 0
	fi

	if [ -n "$icon_path" ] && ! jq -e '(.attrs.image // []) | length > 0' <<<"$live" >/dev/null; then
		verify_fail "oauth app $name missing image"
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
				([.origin] + (.redirectUrls // []))
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
		fi
		while IFS= read -r scope; do
			[ -n "$scope" ] || continue
			if [[ "$scope_map" != *"\"$scope\""* ]]; then
				verify_fail "oauth app $name scope map for '$group_spn' missing '$scope'"
			fi
		done < <(jq -r '.[]' <<<"$scopes_json")
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
	require_login
	kanidm_verify_failed=0

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_person "$item"
	done < <(jq_state '.state.users[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_service_account "$item"
	done < <(jq_state '.state.serviceAccounts[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_group "$item"
	done < <(jq_state '.state.groups[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_group_members "$item"
	done < <(jq_state '.state.groupMembers[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_absent_group "$item"
	done < <(jq_state '.state.absentGroups[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_scim_app "$item"
	done < <(jq_state '.state.scimApps[]?')

	while IFS= read -r item; do
		[ -n "$item" ] || continue
		verify_oauth_app "$item"
	done < <(jq_state '.state.oauthApps[]?')

	[ "$kanidm_verify_failed" -eq 0 ]
}

verify_service_account() {
	local account service_account_id live expected_mail primary_mail actual_primary_mail
	account="$1"
	service_account_id="$(jq_value '.accountId' "$account")"

	live="$(kanidm_json_cmd service-account get "$service_account_id")"

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
	verify_idm
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
	local wait_seconds ready
	local -a curl_args
	wait_seconds="${KANIDM_AUTO_APPLY_WAIT_SECONDS:-60}"
	ready=false

	if [[ ! "$wait_seconds" =~ ^[0-9]+$ ]]; then
		printf 'KANIDM_AUTO_APPLY_WAIT_SECONDS must be an integer, got: %s\n' "$wait_seconds" >&2
		exit 1
	fi

	mapfile -d '' -t curl_args < <(curl_status_args)
	for _ in $(seq 1 "$wait_seconds"); do
		if curl "${curl_args[@]}" "$kanidm_url/status" >/dev/null; then
			ready=true
			break
		fi
		sleep 1
	done

	if [ "$ready" != true ]; then
		curl "${curl_args[@]}" "$kanidm_url/status" >/dev/null
	fi
}

auto_apply_idm() {
	local account_name command desired_stamp login_started_epoch login_output login_rc password_file stamp_file
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
	if auto_apply_stamp_matches "$stamp_file" "$desired_stamp"; then
		printf 'Kanidm %s declarative stamp is current; skipping auto-apply.\n' "$command"
		return 0
	fi

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
			if verify_idm; then
				printf 'Kanidm declared IdM state is already applied; recording auto-apply stamp.\n'
				record_auto_apply_stamp "$stamp_file" "$desired_stamp"
				return
			fi
			apply_idm
			;;
		apply-system)
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
