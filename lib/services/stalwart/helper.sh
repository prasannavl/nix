#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	stalwart_config_host_path="${STALWART_CONFIG_HOST_PATH-}"
	stalwart_cli_bin="${STALWART_CLI_BIN-}"
	stalwart_container="${STALWART_CONTAINER-}"
	stalwart_credentials_file="${STALWART_CREDENTIALS_FILE-}"
	stalwart_data_dir="${STALWART_DATA_DIR-}"
	stalwart_default_certificate="${STALWART_DEFAULT_CERTIFICATE-null}"
	stalwart_domain_id="${STALWART_DOMAIN_ID-}"
	stalwart_extra_recovery_mounts="${STALWART_EXTRA_RECOVERY_MOUNTS-}"
	stalwart_image="${STALWART_IMAGE-}"
	stalwart_kanidm_ldap_token_host_path="${STALWART_KANIDM_LDAP_TOKEN_HOST_PATH-}"
	stalwart_plan_container_path="${STALWART_PLAN_CONTAINER_PATH-}"
	stalwart_plan_host_path="${STALWART_PLAN_HOST_PATH-}"
	stalwart_plan_string_file_substitutions="${STALWART_PLAN_STRING_FILE_SUBSTITUTIONS-}"
	stalwart_prune_certificates="${STALWART_PRUNE_CERTIFICATES-false}"
	stalwart_prune_groups="${STALWART_PRUNE_GROUPS-false}"
	stalwart_prune_mailing_lists="${STALWART_PRUNE_MAILING_LISTS-false}"
	stalwart_prune_mta_routes="${STALWART_PRUNE_MTA_ROUTES-false}"
	stalwart_prune_sieve_system_scripts="${STALWART_PRUNE_SIEVE_SYSTEM_SCRIPTS-false}"
	stalwart_prune_users="${STALWART_PRUNE_USERS-false}"
	stalwart_recovery_container="${STALWART_RECOVERY_CONTAINER-}"
	stalwart_recovery_url="${STALWART_RECOVERY_URL-}"
	stalwart_service_name="${STALWART_SERVICE_NAME-}"
	stalwart_shared_mailboxes_host_path="${STALWART_SHARED_GROUPS_HOST_PATH-}"
	stalwart_url="${STALWART_URL-}"
	stalwart_user_roles_host_path="${STALWART_USER_ROLES_HOST_PATH-}"
	stalwart_mailing_lists_host_path="${STALWART_MAILING_LISTS_HOST_PATH-}"
	stalwart_user="${STALWART_USER-admin}"
	stalwart_password=""
}

require_var() {
	local name value
	name="$1"
	value="${!name-}"
	if [ -z "$value" ]; then
		printf '%s\n' "missing required environment variable: $name" >&2
		exit 1
	fi
}

load_credentials() {
	local raw
	require_var stalwart_credentials_file
	if [ ! -r "$stalwart_credentials_file" ]; then
		printf 'missing readable Stalwart credentials file: %s\n' "$stalwart_credentials_file" >&2
		exit 1
	fi

	raw="$(cat "$stalwart_credentials_file")"
	if [[ "$raw" == *:* ]]; then
		stalwart_user="${raw%%:*}"
		stalwart_password="${raw#*:}"
	else
		stalwart_password="$raw"
	fi
}

stalwart_cli() {
	stalwart_cli_for "$stalwart_container" "$stalwart_url" "$@"
}

stalwart_cli_for() {
	local container url
	local -a network_args volume_args
	container="$1"
	url="$2"
	shift 2
	require_value container "$container"
	require_value url "$url"
	require_var stalwart_cli_bin
	require_var stalwart_image
	if [ ! -x "$stalwart_cli_bin" ]; then
		printf 'missing executable Stalwart CLI: %s\n' "$stalwart_cli_bin" >&2
		exit 1
	fi

	network_args=(--network host)

	volume_args=()
	if [ -n "$stalwart_plan_host_path" ] && [ -n "$stalwart_plan_container_path" ]; then
		volume_args+=(--volume "$stalwart_plan_host_path:$stalwart_plan_container_path:ro")
	fi

	podman run \
		--interactive \
		--rm \
		"${network_args[@]}" \
		--entrypoint /usr/local/bin/stalwart-cli \
		--env HOME=/tmp \
		--env "STALWART_URL=$url" \
		--env "STALWART_USER=$stalwart_user" \
		--env "STALWART_PASSWORD=$stalwart_password" \
		--volume "$stalwart_cli_bin:/usr/local/bin/stalwart-cli:ro" \
		"${volume_args[@]}" \
		"$stalwart_image" \
		"$@"
}

require_value() {
	local name value
	name="$1"
	value="$2"
	if [ -z "$value" ]; then
		printf '%s\n' "missing required value: $name" >&2
		exit 1
	fi
}

state_dir() {
	local base
	base="${STALWART_DECLARATIVE_STATE_DIR-}"
	if [ -z "$base" ]; then
		base="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/stalwart-declarative"
	fi
	printf '%s\n' "$base"
}

state_name() {
	local name
	name="${stalwart_service_name:-stalwart-apply}"
	name="${name//[^A-Za-z0-9_.-]/_}"
	printf '%s\n' "$name"
}

managed_users_file() {
	printf '%s/%s.users' "$(state_dir)" "$(state_name)"
}

managed_certificates_file() {
	printf '%s/%s.certificates' "$(state_dir)" "$(state_name)"
}

managed_mta_routes_file() {
	printf '%s/%s.mta-routes' "$(state_dir)" "$(state_name)"
}

managed_sieve_system_scripts_file() {
	printf '%s/%s.sieve-system-scripts' "$(state_dir)" "$(state_name)"
}

prune_certificates_enabled() {
	[ "$stalwart_prune_certificates" = true ]
}

prune_groups_enabled() {
	[ "$stalwart_prune_groups" = true ]
}

prune_mailing_lists_enabled() {
	[ "$stalwart_prune_mailing_lists" = true ]
}

prune_mta_routes_enabled() {
	[ "$stalwart_prune_mta_routes" = true ]
}

prune_sieve_system_scripts_enabled() {
	[ "$stalwart_prune_sieve_system_scripts" = true ]
}

prune_users_enabled() {
	[ "$stalwart_prune_users" = true ]
}

stage_recovery_file() {
	local source_path target_name staged_path
	source_path="$1"
	target_name="$2"
	require_var stalwart_recovery_secret_dir

	staged_path="$stalwart_recovery_secret_dir/$target_name"
	cp -- "$source_path" "$staged_path"
	chmod 0444 "$staged_path"
	printf '%s\n' "$staged_path"
}

prepare_plan_host_path() {
	local source_path staged_plan placeholder file_path value tmp

	source_path="$stalwart_plan_host_path"
	if [ -z "$stalwart_plan_string_file_substitutions" ]; then
		printf '%s\n' "$source_path"
		return
	fi

	require_var stalwart_recovery_secret_dir
	staged_plan="$stalwart_recovery_secret_dir/plan.json"
	cp -- "$source_path" "$staged_plan"
	chmod 0444 "$staged_plan"

	while IFS=$'\t' read -r placeholder file_path; do
		[ -n "$placeholder" ] || continue
		require_value "plan substitution source for $placeholder" "$file_path"
		if [ ! -r "$file_path" ]; then
			printf 'missing readable plan substitution source for %s: %s\n' "$placeholder" "$file_path" >&2
			exit 1
		fi

		value="$(cat "$file_path")"
		tmp="$(mktemp "${staged_plan}.XXXXXX")"
		jq -c \
			--arg placeholder "$placeholder" \
			--arg value "$value" \
			'walk(if type == "string" and . == $placeholder then $value else . end)' \
			"$staged_plan" >"$tmp"
		mv -- "$tmp" "$staged_plan"
		chmod 0444 "$staged_plan"
	done <<<"$stalwart_plan_string_file_substitutions"

	printf '%s\n' "$staged_plan"
}

with_recovery() {
	require_var stalwart_config_host_path
	require_var stalwart_container
	require_var stalwart_data_dir
	require_var stalwart_image
	require_var stalwart_kanidm_ldap_token_host_path
	require_var stalwart_plan_container_path
	require_var stalwart_plan_host_path
	require_var stalwart_recovery_container
	require_value stalwart_recovery_url "$stalwart_recovery_url"
	require_var stalwart_service_name

	local lock_name lock_path mount host_path container_path staged_kanidm_token staged_mount
	local extra_mount_index=0
	local -a extra_volume_args=()
	lock_name="${stalwart_service_name//[^A-Za-z0-9_.-]/_}"
	lock_path="${XDG_RUNTIME_DIR:-/tmp}/stalwart-apply-${lock_name}.lock"
	exec 9>"$lock_path"
	flock 9

	stalwart_recovery_secret_dir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/stalwart-recovery-secrets.XXXXXX")"
	trap 'podman rm -f "$stalwart_recovery_container" >/dev/null 2>&1 || true; systemctl --user start "$stalwart_service_name" || true; rm -rf "$stalwart_recovery_secret_dir"' EXIT

	while IFS= read -r mount; do
		[ -n "$mount" ] || continue
		host_path="${mount%%:*}"
		container_path="${mount#*:}"
		if [ ! -r "$host_path" ]; then
			printf 'missing readable recovery mount source: %s\n' "$host_path" >&2
			exit 1
		fi
		extra_mount_index=$((extra_mount_index + 1))
		staged_mount="$(stage_recovery_file "$host_path" "extra-$extra_mount_index")"
		extra_volume_args+=(--volume "$staged_mount:$container_path:ro")
	done <<<"$stalwart_extra_recovery_mounts"

	if [ ! -r "$stalwart_config_host_path" ]; then
		printf 'missing readable Stalwart config file: %s\n' "$stalwart_config_host_path" >&2
		exit 1
	fi
	if [ ! -r "$stalwart_plan_host_path" ]; then
		printf 'missing readable Stalwart plan file: %s\n' "$stalwart_plan_host_path" >&2
		exit 1
	fi
	if [ ! -r "$stalwart_kanidm_ldap_token_host_path" ]; then
		printf 'missing readable Kanidm LDAP token file: %s\n' "$stalwart_kanidm_ldap_token_host_path" >&2
		exit 1
	fi
	staged_kanidm_token="$(stage_recovery_file "$stalwart_kanidm_ldap_token_host_path" "kanidm-ldap-token")"
	stalwart_plan_host_path="$(prepare_plan_host_path)"

	systemctl --user stop "$stalwart_service_name" || true
	podman rm -f "$stalwart_recovery_container" >/dev/null 2>&1 || true
	podman run \
		--detach \
		--name "$stalwart_recovery_container" \
		--rm \
		--env STALWART_RECOVERY_MODE=1 \
		--env "STALWART_RECOVERY_ADMIN=$stalwart_user:$stalwart_password" \
		--publish 127.0.0.1:18081:8080 \
		--volume "$stalwart_config_host_path:/etc/stalwart/config.json:ro" \
		--volume "$stalwart_plan_host_path:$stalwart_plan_container_path:ro" \
		--volume "$stalwart_data_dir:/var/lib/stalwart" \
		--volume "$staged_kanidm_token:/run/secrets/kanidm-ldap-token:ro" \
		"${extra_volume_args[@]}" \
		"$stalwart_image" >/dev/null

	sleep 5
	"$@"
}

apply_with_recovery() {
	with_recovery \
		apply_plan "$@"
}

has_arg() {
	local expected arg
	expected="$1"
	shift
	for arg in "$@"; do
		[ "$arg" = "$expected" ] && return 0
	done
	return 1
}

apply_plan() {
	stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
		apply --file "$stalwart_plan_container_path" "$@"

	if ! has_arg --dry-run "$@"; then
		reconcile_default_certificate
		prune_obsolete_certificates
		prune_obsolete_mta_routes
		prune_obsolete_sieve_system_scripts
		reconcile_shared_mailboxes
		reconcile_mailing_lists
		reconcile_user_roles
		remember_declared_certificates
		remember_declared_mta_routes
		remember_declared_sieve_system_scripts
	fi
}

desired_certificate_paths() {
	[ "$stalwart_default_certificate" != "null" ] || return 0
	jq -r '
		.certificate.filePath // .certificate.value.filePath // empty
	' <<<"$stalwart_default_certificate"
}

desired_mta_route_names() {
	[ -n "$stalwart_plan_host_path" ] || return 0
	[ -r "$stalwart_plan_host_path" ] || return 0
	jq -r '
		select(."@type" == "create" and .object == "MtaRoute")
		| .value
		| keys[]?
	' "$stalwart_plan_host_path" | LC_ALL=C sort -u
}

desired_sieve_system_script_names() {
	[ -n "$stalwart_plan_host_path" ] || return 0
	[ -r "$stalwart_plan_host_path" ] || return 0
	jq -r '
		select(."@type" == "create" and .object == "SieveSystemScript")
		| .value
		| keys[]?
	' "$stalwart_plan_host_path" | LC_ALL=C sort -u
}

reconcile_default_certificate() {
	local certificate certificate_id patch query_output

	[ "$stalwart_default_certificate" != "null" ] || return 0
	certificate="$(jq -c '.' <<<"$stalwart_default_certificate")"
	certificate_id="$(find_default_certificate_id "$certificate")"

	if [ -z "$certificate_id" ]; then
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			create Certificate \
			--json "$certificate" \
			--no-color

		query_output="$(
			stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
				query Certificate \
				--fields id,certificate \
				--json
		)"
		certificate_id="$(find_default_certificate_id_from_query "$certificate" "$query_output")"
	fi

	require_value "default certificate id" "$certificate_id"
	patch="$(jq -n -c --arg id "$certificate_id" '{defaultCertificateId: $id}')"
	stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
		update SystemSettings singleton \
		--json "$patch" \
		--no-color
	printf 'Stalwart certificate: selected default certificate %s\n' "$certificate_id"
}

prune_obsolete_certificates() {
	local state_file desired_keys previous query_output certificate id path
	prune_certificates_enabled || return 0

	state_file="$(managed_certificates_file)"
	install -d -m 0700 "$(dirname "$state_file")"
	if [ ! -e "$state_file" ]; then
		return 0
	fi

	desired_keys="$(
		desired_certificate_paths |
			jq -Rn '
				[inputs | select(. != "") | {key: ., value: true}]
				| from_entries
			'
	)"
	query_output="$(
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			query Certificate \
			--fields id,certificate \
			--json
	)"

	while IFS= read -r previous; do
		[ -n "$previous" ] || continue
		if jq -e --arg key "$previous" 'has($key)' <<<"$desired_keys" >/dev/null; then
			continue
		fi
		while IFS= read -r -u 4 certificate; do
			id="$(jq -r '.id // empty' <<<"$certificate")"
			path="$(jq -r '.certificate.filePath // .certificate.value.filePath // empty' <<<"$certificate")"
			[ -n "$id" ] || continue
			[ "$path" = "$previous" ] || continue
			stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
				delete Certificate \
				--ids "$id" \
				--no-color
			printf 'Stalwart certificate: deleted obsolete managed certificate %s\n' "$path"
		done 4< <(jq -c '.' <<<"$query_output")
	done <"$state_file"
}

remember_declared_certificates() {
	local state_file tmp_file

	state_file="$(managed_certificates_file)"
	install -d -m 0700 "$(dirname "$state_file")"
	tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
	desired_certificate_paths >"$tmp_file"
	mv "$tmp_file" "$state_file"
}

prune_obsolete_mta_routes() {
	local state_file desired_keys previous query_output route id name
	prune_mta_routes_enabled || return 0

	state_file="$(managed_mta_routes_file)"
	install -d -m 0700 "$(dirname "$state_file")"
	if [ ! -e "$state_file" ]; then
		return 0
	fi

	desired_keys="$(
		desired_mta_route_names |
			jq -Rn '
				[inputs | select(. != "") | {key: ., value: true}]
				| from_entries
			'
	)"
	query_output="$(
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			query MtaRoute \
			--fields id,name \
			--json
	)"

	while IFS= read -r previous; do
		[ -n "$previous" ] || continue
		if jq -e --arg key "$previous" 'has($key)' <<<"$desired_keys" >/dev/null; then
			continue
		fi
		while IFS= read -r -u 4 route; do
			id="$(jq -r '.id // empty' <<<"$route")"
			name="$(jq -r '.name // empty' <<<"$route")"
			[ -n "$id" ] || continue
			[ "$name" = "$previous" ] || continue
			stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
				delete MtaRoute \
				--ids "$id" \
				--no-color
			printf 'Stalwart MTA route: deleted obsolete managed route %s\n' "$name"
		done 4< <(jq -c '.' <<<"$query_output")
	done <"$state_file"
}

remember_declared_mta_routes() {
	local state_file tmp_file

	state_file="$(managed_mta_routes_file)"
	install -d -m 0700 "$(dirname "$state_file")"
	tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
	desired_mta_route_names >"$tmp_file"
	mv "$tmp_file" "$state_file"
}

prune_obsolete_sieve_system_scripts() {
	local state_file desired_keys previous query_output script id name
	prune_sieve_system_scripts_enabled || return 0

	state_file="$(managed_sieve_system_scripts_file)"
	install -d -m 0700 "$(dirname "$state_file")"
	if [ ! -e "$state_file" ]; then
		return 0
	fi

	desired_keys="$(
		desired_sieve_system_script_names |
			jq -Rn '
				[inputs | select(. != "") | {key: ., value: true}]
				| from_entries
			'
	)"
	query_output="$(
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			query SieveSystemScript \
			--fields id,name \
			--json
	)"

	while IFS= read -r previous; do
		[ -n "$previous" ] || continue
		if jq -e --arg key "$previous" 'has($key)' <<<"$desired_keys" >/dev/null; then
			continue
		fi
		while IFS= read -r -u 4 script; do
			id="$(jq -r '.id // empty' <<<"$script")"
			name="$(jq -r '.name // empty' <<<"$script")"
			[ -n "$id" ] || continue
			[ "$name" = "$previous" ] || continue
			stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
				delete SieveSystemScript \
				--ids "$id" \
				--no-color
			printf 'Stalwart sieve system script: deleted obsolete managed script %s\n' "$name"
		done 4< <(jq -c '.' <<<"$query_output")
	done <"$state_file"
}

remember_declared_sieve_system_scripts() {
	local state_file tmp_file

	state_file="$(managed_sieve_system_scripts_file)"
	install -d -m 0700 "$(dirname "$state_file")"
	tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
	desired_sieve_system_script_names >"$tmp_file"
	mv "$tmp_file" "$state_file"
}

reconcile_shared_mailboxes() {
	local shared_group id desired domain_id name patch

	[ -n "$stalwart_shared_mailboxes_host_path" ] || return 0
	[ -s "$stalwart_shared_mailboxes_host_path" ] || return 0

	prune_obsolete_shared_mailboxes

	while IFS= read -r -u 3 shared_group; do
		name="$(jq -r '.name' <<<"$shared_group")"
		domain_id="$(jq -r '.domainId' <<<"$shared_group")"

		require_value "shared mailbox name" "$name"
		require_value "shared mailbox domainId" "$domain_id"

		desired="$(jq -c '{
			"@type": "Group",
			name,
			domainId,
			description: (.description // null),
			aliases: ((.aliases // {}) | if type == "array" then to_entries | map({key: (.key | tostring), value: (.value + {description: (.value.description // null)})}) | from_entries else . end)
		}' <<<"$shared_group")"

		id="$(find_shared_mailbox_id "$domain_id" "$name")"

		if [ -n "$id" ]; then
			patch="$(jq -c 'del(."@type", .name, .domainId)' <<<"$desired")"
			stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
				update Account "$id" \
				--json "$patch" \
				--no-color
			printf 'Stalwart shared mailbox: updated %s in domain %s\n' "$name" "$domain_id"
		else
			stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
				create Account/Group \
				--json "$desired" \
				--no-color
			printf 'Stalwart shared mailbox: created %s in domain %s\n' "$name" "$domain_id"
		fi
	done 3< <(jq -c '.[]' "$stalwart_shared_mailboxes_host_path")
}

find_shared_mailbox_id() {
	local domain_id name query_output
	domain_id="$1"
	name="$2"

	query_output="$(
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			query Account \
			--where "name=$name" \
			--where "domainId=$domain_id" \
			--fields id,name,domainId,description \
			--json
	)"

	jq -s -r \
		--arg domain_id "$domain_id" \
		--arg name "$name" \
		'map(select(.name == $name and .domainId == $domain_id)) | first.id // empty' \
		<<<"$query_output"
}

prune_obsolete_shared_mailboxes() {
	local desired_keys query_output account id name domain_id description key

	prune_groups_enabled || return 0

	desired_keys="$(
		jq -c '
			map({key: (.domainId + "\t" + .name), value: true})
			| from_entries
		' "$stalwart_shared_mailboxes_host_path"
	)"

	query_output="$(
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			query Account \
			--fields id,name,domainId,description \
			--json
	)"

	while IFS= read -r -u 4 account; do
		id="$(jq -r '.id // empty' <<<"$account")"
		name="$(jq -r '.name // empty' <<<"$account")"
		domain_id="$(jq -r '.domainId // empty' <<<"$account")"
		description="$(jq -r '.description // empty' <<<"$account")"
		[ -n "$id" ] || continue
		[ -n "$name" ] || continue
		[ -n "$domain_id" ] || continue
		if [[ "$description" != Userdata-managed\ *\ shared\ mailbox. ]]; then
			continue
		fi

		key="${domain_id}"$'\t'"${name}"
		if jq -e --arg key "$key" 'has($key)' <<<"$desired_keys" >/dev/null; then
			continue
		fi

		remove_account_group_references "$id"
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			delete Account \
			--ids "$id" \
			--no-color
		printf 'Stalwart shared mailbox: deleted obsolete userdata-managed mailbox %s in domain %s\n' "$name" "$domain_id"
	done 4< <(jq -c '.' <<<"$query_output")
}

find_default_certificate_id() {
	local certificate query_output
	certificate="$1"

	query_output="$(
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			query Certificate \
			--fields id,certificate \
			--json
	)"

	find_default_certificate_id_from_query "$certificate" "$query_output"
}

find_default_certificate_id_from_query() {
	local certificate query_output
	certificate="$1"
	query_output="$2"

	jq -s -r \
		--argjson desired "$certificate" \
		'
			def file_path:
				.certificate.filePath // .certificate.value.filePath // empty;

			($desired.certificate.filePath // $desired.certificate.value.filePath) as $certificate_path
			| map(select(file_path == $certificate_path))
			| first.id // empty
		' \
		<<<"$query_output"
}

reconcile_mailing_lists() {
	local alias_names mailing_list id desired domain_id identity_names name patch

	[ -n "$stalwart_mailing_lists_host_path" ] || return 0
	[ -s "$stalwart_mailing_lists_host_path" ] || return 0

	prune_obsolete_mailing_lists

	while IFS= read -r -u 3 mailing_list; do
		name="$(jq -r '.name' <<<"$mailing_list")"
		domain_id="$(jq -r '.domainId' <<<"$mailing_list")"

		require_value "mailing list name" "$name"
		require_value "mailing list domainId" "$domain_id"

		alias_names="$(jq -c '(.aliases // {}) | if type == "array" then map(.name) else [.[] | .name] end' <<<"$mailing_list")"
		remove_account_aliases "$domain_id" "$alias_names"
		identity_names="$(mailing_list_identity_names "$mailing_list")"
		remove_account_name_collisions "$domain_id" "$identity_names"

		desired="$(jq -c '{
			name,
			domainId,
			description: (.description // null),
			recipients: ((.recipients // {}) | if type == "array" then map({key: ., value: true}) | from_entries else . end),
			aliases: ((.aliases // {}) | if type == "array" then to_entries | map({key: (.key | tostring), value: (.value + {description: (.value.description // null)})}) | from_entries else . end)
		}' <<<"$mailing_list")"

		id="$(find_mailing_list_id "$domain_id" "$name" "$mailing_list")"

		if [ -n "$id" ]; then
			patch="$(jq -c 'del(.name, .domainId)' <<<"$desired")"
			stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
				update MailingList "$id" \
				--json "$patch" \
				--no-color
			printf 'Stalwart mailing list: updated %s in domain %s\n' "$name" "$domain_id"
		else
			stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
				create MailingList \
				--json "$desired" \
				--no-color
			printf 'Stalwart mailing list: created %s in domain %s\n' "$name" "$domain_id"
		fi
	done 3< <(jq -c '.[]' "$stalwart_mailing_lists_host_path")
}

mailing_list_identity_names() {
	jq -c '
		([.name] + ((.aliases // {}) | if type == "array" then map(.name) else [.[] | .name] end))
		| map(select(. != null and . != ""))
		| unique
	' <<<"$1"
}

find_mailing_list_id() {
	local domain_id name desired query_output
	domain_id="$1"
	name="$2"
	desired="$3"

	query_output="$(
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			query MailingList \
			--fields id,name,domainId,description,recipients,aliases \
			--json
	)"

	jq -s -r \
		--arg domain_id "$domain_id" \
		--arg name "$name" \
		--argjson desired "$desired" \
		'
			def alias_names($object):
				($object.aliases // {})
				| if type == "array" then . else [.[]] end
				| map(select((.domainId // $domain_id) == $domain_id) | .name);

			def desired_names:
				([$desired.name] + alias_names($desired))
				| map(select(. != null and . != ""))
				| unique;

			def same_domain:
				select(.domainId == $domain_id);

			def owns_desired_identity:
				(.name as $list_name | (desired_names | index($list_name)) != null)
				or ((alias_names(.) | any(. as $alias | (desired_names | index($alias)) != null)));

			(map(same_domain | select(.name == $name)) | first.id)
			// (map(same_domain | select(owns_desired_identity)) | first.id)
			// empty
		' \
		<<<"$query_output"
}

prune_obsolete_mailing_lists() {
	local desired_keys query_output mailing_list id name domain_id description key

	prune_mailing_lists_enabled || return 0

	desired_keys="$(
		jq -c '
			map(
				. as $list
				| ([{name: $list.name, domainId: $list.domainId}]
					+ ((.aliases // {}) | if type == "array" then . else [.[]] end))
				| map(select((.name // "") != ""))
				| map({key: ((.domainId // $list.domainId) + "\t" + .name), value: true})
			)
			| add // []
			| from_entries
		' "$stalwart_mailing_lists_host_path"
	)"

	query_output="$(
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			query MailingList \
			--fields id,name,domainId,description \
			--json
	)"

	while IFS= read -r -u 4 mailing_list; do
		id="$(jq -r '.id // empty' <<<"$mailing_list")"
		name="$(jq -r '.name // empty' <<<"$mailing_list")"
		domain_id="$(jq -r '.domainId // empty' <<<"$mailing_list")"
		description="$(jq -r '.description // empty' <<<"$mailing_list")"
		[ -n "$id" ] || continue
		[ -n "$name" ] || continue
		[ -n "$domain_id" ] || continue
		if [[ "$description" != Userdata-managed\ *\ mailing\ list. ]]; then
			continue
		fi

		key="${domain_id}"$'\t'"${name}"
		if jq -e --arg key "$key" 'has($key)' <<<"$desired_keys" >/dev/null; then
			continue
		fi

		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			delete MailingList \
			--ids "$id" \
			--no-color
		printf 'Stalwart mailing list: deleted obsolete userdata-managed list %s in domain %s\n' "$name" "$domain_id"
	done 4< <(jq -c '.' <<<"$query_output")
}

remove_account_name_collisions() {
	local account account_id account_name domain_id identity_names protected_names query_output roles aliases description

	domain_id="$1"
	identity_names="$2"
	[ "$(jq 'length' <<<"$identity_names")" -gt 0 ] || return 0

	protected_names="[]"
	if [ -n "$stalwart_user_roles_host_path" ] && [ -s "$stalwart_user_roles_host_path" ]; then
		protected_names="$(jq -c --arg domain_id "$domain_id" 'map(select(.domainId == $domain_id) | .name) | unique' "$stalwart_user_roles_host_path")"
	fi

	query_output="$(
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			query Account \
			--where "domainId=$domain_id" \
			--fields id,name,domainId,description,roles,aliases \
			--json
	)"

	while IFS= read -r -u 4 account; do
		account_name="$(jq -r '.name // empty' <<<"$account")"
		[ -n "$account_name" ] || continue
		if ! jq -e --arg name "$account_name" 'index($name) != null' <<<"$identity_names" >/dev/null; then
			continue
		fi
		if jq -e --arg name "$account_name" 'index($name) != null' <<<"$protected_names" >/dev/null; then
			printf 'Stalwart mailing list: account %s in domain %s collides with a desired mailing-list identity and is a managed user; refusing automatic migration\n' "$account_name" "$domain_id" >&2
			exit 1
		fi

		account_id="$(jq -r '.id // empty' <<<"$account")"
		roles="$(jq -r '.roles."@type" // ""' <<<"$account")"
		aliases="$(jq -c '(.aliases // {}) | if type == "array" then . else [.[]] end' <<<"$account")"
		description="$(jq -r '.description // empty' <<<"$account")"
		require_value "account id" "$account_id"

		if [ "$roles" = "Default" ] && [ "$(jq 'length' <<<"$aliases")" -eq 0 ] && [ -z "$description" ]; then
			remove_account_group_references "$account_id"
			stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
				delete Account \
				--ids "$account_id" \
				--no-color
			printf 'Stalwart mailing list: deleted stale account identity %s in domain %s before claiming mailing-list address\n' "$account_name" "$domain_id"
			continue
		fi

		printf 'Stalwart mailing list: account %s in domain %s collides with a desired mailing-list identity; refusing to delete non-empty or non-default account %s\n' "$account_name" "$domain_id" "$account_id" >&2
		exit 1
	done 4< <(jq -c '.' <<<"$query_output")
}

remove_account_group_references() {
	local group_id account account_id filtered member_group_ids patch query_output

	group_id="$1"
	require_value "group account id" "$group_id"

	query_output="$(
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			query Account \
			--fields id,name,memberGroupIds \
			--json
	)"

	while IFS= read -r -u 5 account; do
		member_group_ids="$(jq -c '.memberGroupIds // {}' <<<"$account")"
		if ! jq -e --arg group_id "$group_id" 'has($group_id)' <<<"$member_group_ids" >/dev/null; then
			continue
		fi

		account_id="$(jq -r '.id // empty' <<<"$account")"
		require_value "account id" "$account_id"

		filtered="$(jq -c --arg group_id "$group_id" 'del(.[$group_id])' <<<"$member_group_ids")"
		patch="$(jq -n -c --argjson member_group_ids "$filtered" '{memberGroupIds: $member_group_ids}')"
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			update Account "$account_id" \
			--json "$patch" \
			--no-color
		printf 'Stalwart mailing list: removed stale group membership %s from account %s\n' "$group_id" "$(jq -r '.name // .id' <<<"$account")"
	done 5< <(jq -c '.' <<<"$query_output")
}

remove_account_aliases() {
	local domain_id alias_names account account_id current filtered query_output

	domain_id="$1"
	alias_names="$2"
	[ "$(jq 'length' <<<"$alias_names")" -gt 0 ] || return 0

	query_output="$(
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			query Account \
			--where "domainId=$domain_id" \
			--fields id,name,domainId,aliases \
			--json
	)"

	while IFS= read -r -u 4 account; do
		account_id="$(jq -r '.id' <<<"$account")"
		require_value "account id" "$account_id"

		current="$(jq -c '(.aliases // {}) | if type == "array" then to_entries | map({key: (.key | tostring), value: .value}) | from_entries else . end' <<<"$account")"
		filtered="$(
			jq -c --arg domain_id "$domain_id" --argjson alias_names "$alias_names" '
				(.aliases // {})
				| if type == "array" then to_entries | map({key: (.key | tostring), value: .value}) | from_entries else . end
				| to_entries
				| map(select(
					(.value.name // "") as $name
					| (.value.domainId // $domain_id) as $alias_domain_id
					| $alias_domain_id != $domain_id or ($alias_names | index($name)) == null
				))
				| map(.value)
				| to_entries
				| map({key: (.key | tostring), value: .value})
				| from_entries
			' <<<"$account"
		)"

		if [ "$current" = "$filtered" ]; then
			continue
		fi

		patch="$(jq -n -c --argjson aliases "$filtered" '{aliases: $aliases}')"
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			update Account "$account_id" \
			--json "$patch" \
			--no-color
		printf 'Stalwart account aliases: removed mailing-list aliases from %s\n' "$(jq -r '.name' <<<"$account")"
	done 4< <(jq -c '.' <<<"$query_output")
}

declared_user_keys() {
	[ -n "$stalwart_user_roles_host_path" ] || return 0
	[ -s "$stalwart_user_roles_host_path" ] || return 0
	jq -r '.[]? | (.domainId + "\t" + .name)' "$stalwart_user_roles_host_path" | LC_ALL=C sort -u
}

remember_declared_users() {
	local state_file tmp_file

	[ -n "$stalwart_user_roles_host_path" ] || return 0
	[ -s "$stalwart_user_roles_host_path" ] || return 0

	state_file="$(managed_users_file)"
	install -d -m 0700 "$(dirname "$state_file")"
	tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"
	declared_user_keys >"$tmp_file"
	mv "$tmp_file" "$state_file"
}

prune_obsolete_users() {
	local state_file previous_keys desired_keys query_output account account_id name domain_id key

	prune_users_enabled || return 0
	[ -n "$stalwart_user_roles_host_path" ] || return 0
	[ -s "$stalwart_user_roles_host_path" ] || return 0

	state_file="$(managed_users_file)"
	install -d -m 0700 "$(dirname "$state_file")"
	if [ ! -e "$state_file" ]; then
		return 0
	fi

	previous_keys="$(
		jq -Rn '
			[inputs | select(. != "") | {key: ., value: true}]
			| from_entries
		' "$state_file"
	)"
	desired_keys="$(
		declared_user_keys |
			jq -Rn '
				[inputs | select(. != "") | {key: ., value: true}]
				| from_entries
			'
	)"
	query_output="$(
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			query Account \
			--fields id,name,domainId \
			--json
	)"

	while IFS= read -r -u 4 account; do
		account_id="$(jq -r '.id // empty' <<<"$account")"
		name="$(jq -r '.name // empty' <<<"$account")"
		domain_id="$(jq -r '.domainId // empty' <<<"$account")"
		[ -n "$account_id" ] || continue
		[ -n "$name" ] || continue
		[ -n "$domain_id" ] || continue

		key="${domain_id}"$'\t'"${name}"
		if ! jq -e --arg key "$key" 'has($key)' <<<"$previous_keys" >/dev/null; then
			continue
		fi
		if jq -e --arg key "$key" 'has($key)' <<<"$desired_keys" >/dev/null; then
			continue
		fi

		remove_account_group_references "$account_id"
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			delete Account \
			--ids "$account_id" \
			--no-color
		printf 'Stalwart user: deleted obsolete userdata-managed account %s in domain %s\n' "$name" "$domain_id"
	done 4< <(jq -c '.' <<<"$query_output")
}

reconcile_user_roles() {
	local account account_id current_role domain_id name patch query_output role

	[ -n "$stalwart_user_roles_host_path" ] || return 0
	[ -s "$stalwart_user_roles_host_path" ] || return 0

	prune_obsolete_users

	while IFS= read -r -u 3 account; do
		name="$(jq -r '.name' <<<"$account")"
		domain_id="$(jq -r '.domainId' <<<"$account")"
		role="$(jq -r '.role' <<<"$account")"

		require_value "user role name" "$name"
		require_value "user role domainId" "$domain_id"
		require_value "user role role" "$role"
		case "$role" in
		User | Admin) ;;
		*)
			printf 'unsupported Stalwart role for %s: %s\n' "$name" "$role" >&2
			exit 1
			;;
		esac

		query_output="$(
			stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
				query Account \
				--where "name=$name" \
				--where "domainId=$domain_id" \
				--fields id,name,domainId,roles \
				--json
		)"
		account="$(
			jq -s -c \
				--arg name "$name" \
				--arg domain_id "$domain_id" \
				'map(select(.name == $name and .domainId == $domain_id)) | first // empty' \
				<<<"$query_output"
		)"

		if [ -z "$account" ]; then
			printf 'Stalwart role: skipping missing account %s in domain %s\n' "$name" "$domain_id"
			continue
		fi

		account_id="$(jq -r '.id' <<<"$account")"
		current_role="$(jq -r '.roles."@type" // ""' <<<"$account")"
		if [ "$current_role" = "$role" ]; then
			printf 'Stalwart role: %s already %s\n' "$name" "$role"
			continue
		fi

		patch="$(jq -n -c --arg role "$role" '{roles: {"@type": $role}}')"
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
			update Account "$account_id" \
			--json "$patch" \
			--no-color
		printf 'Stalwart role: set %s to %s\n' "$name" "$role"
	done 3< <(jq -c '.[]' "$stalwart_user_roles_host_path")

	remember_declared_users
}

recovery_cli() {
	with_recovery \
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
		"$@"
}

dns_zone() {
	require_var stalwart_domain_id
	with_recovery \
		stalwart_cli_for "$stalwart_recovery_container" "$stalwart_recovery_url" \
		get Domain "$stalwart_domain_id" --fields dnsZoneFile "$@"
}

usage() {
	cat <<USAGE
Usage: $(basename "$0") <command> [args...]

Commands:
  bootstrap   Compatibility alias for apply.
  apply       Stop the normal service, apply through a recovery container, then restart it.
  dry-run     Validate the rendered plan through a recovery container, then restart the service.
  dns-zone    Print generated DNS zone data for the configured domain through recovery mode.
  cli ...     Run stalwart-cli beside the Stalwart container network namespace.
  recovery-cli ...
              Run stalwart-cli against a temporary recovery container.

The credentials file may contain either "user:password" or just a password.
When it contains only a password, STALWART_USER defaults to "admin".
Run this as the podman stack user so it can access the rootless container.
USAGE
}

main() {
	local command
	init_vars

	command="${1:-apply}"
	shift || true

	case "$command" in
	bootstrap)
		load_credentials
		apply_with_recovery "$@"
		;;
	apply)
		load_credentials
		apply_with_recovery "$@"
		;;
	dry-run)
		load_credentials
		apply_with_recovery --dry-run "$@"
		;;
	dns-zone)
		load_credentials
		dns_zone "$@"
		;;
	cli)
		load_credentials
		stalwart_cli "$@"
		;;
	recovery-cli)
		load_credentials
		recovery_cli "$@"
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
