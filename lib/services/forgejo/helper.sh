#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	forgejo_admin_group="${FORGEJO_ADMIN_GROUP-}"
	forgejo_auth_name="${FORGEJO_AUTH_NAME-kanidm}"
	forgejo_client_id="${FORGEJO_CLIENT_ID-}"
	forgejo_client_secret_file="${FORGEJO_CLIENT_SECRET_FILE-}"
	forgejo_config_path="${FORGEJO_CONFIG_PATH-/var/lib/gitea/custom/conf/app.ini}"
	forgejo_container="${FORGEJO_CONTAINER-forgejo_forgejo_1}"
	forgejo_group_claim_name="${FORGEJO_GROUP_CLAIM_NAME-groups}"
	forgejo_issuer_url="${FORGEJO_ISSUER_URL-}"
	forgejo_wait_seconds="${FORGEJO_WAIT_SECONDS-120}"
	forgejo_work_path="${FORGEJO_WORK_PATH-/var/lib/gitea}"
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

load_client_secret() {
	require_value forgejo_client_secret_file "$forgejo_client_secret_file"
	if [ ! -r "$forgejo_client_secret_file" ]; then
		printf 'missing readable Forgejo client secret file: %s\n' "$forgejo_client_secret_file" >&2
		exit 1
	fi
	tr -d '\r\n' <"$forgejo_client_secret_file"
}

forgejo_cli() {
	podman exec "$forgejo_container" forgejo \
		--work-path "$forgejo_work_path" \
		--config "$forgejo_config_path" \
		"$@"
}

wait_for_forgejo() {
	local elapsed output
	elapsed=0

	while true; do
		if output="$(forgejo_cli admin auth list --vertical-bars 2>&1)"; then
			return 0
		fi

		if [ "$elapsed" -ge "$forgejo_wait_seconds" ]; then
			printf '%s\n' "$output" >&2
			printf 'Forgejo did not become ready for auth reconciliation after %ss\n' "$forgejo_wait_seconds" >&2
			exit 1
		fi

		sleep 2
		elapsed=$((elapsed + 2))
	done
}

wait_for_oidc_discovery() {
	local discovery_url elapsed output
	discovery_url="${forgejo_issuer_url}/.well-known/openid-configuration"
	elapsed=0

	while true; do
		if output="$(curl --fail --silent --show-error --location --max-time 10 "$discovery_url" 2>&1)"; then
			return 0
		fi

		if [ "$elapsed" -ge "$forgejo_wait_seconds" ]; then
			printf '%s\n' "$output" >&2
			printf 'Forgejo OIDC discovery URL did not become ready after %ss: %s\n' "$forgejo_wait_seconds" "$discovery_url" >&2
			exit 1
		fi

		sleep 2
		elapsed=$((elapsed + 2))
	done
}

find_auth_source_id() {
	forgejo_cli admin auth list --vertical-bars |
		awk -F'|' -v name="$forgejo_auth_name" '
			{
				for (i = 1; i <= NF; i++) {
					gsub(/^[ \t]+|[ \t]+$/, "", $i)
				}
				if ($2 == name || $3 == name) {
					print $1
					exit
				}
			}
		'
}

oauth_args() {
	local client_secret
	client_secret="$1"

	printf '%s\0' \
		--name "$forgejo_auth_name" \
		--provider openidConnect \
		--key "$forgejo_client_id" \
		--secret "$client_secret" \
		--auto-discover-url "${forgejo_issuer_url}/.well-known/openid-configuration" \
		--scopes openid \
		--scopes profile \
		--scopes email \
		--scopes groups \
		--group-claim-name "$forgejo_group_claim_name"

	if [ -n "$forgejo_admin_group" ]; then
		printf '%s\0' --admin-group "$forgejo_admin_group"
	fi
}

apply_oauth() {
	local auth_source_id client_secret
	local -a args

	require_value forgejo_auth_name "$forgejo_auth_name"
	require_value forgejo_client_id "$forgejo_client_id"
	require_value forgejo_issuer_url "$forgejo_issuer_url"
	require_value forgejo_container "$forgejo_container"
	require_value forgejo_config_path "$forgejo_config_path"
	require_value forgejo_work_path "$forgejo_work_path"

	client_secret="$(load_client_secret)"
	wait_for_forgejo
	wait_for_oidc_discovery

	mapfile -d '' -t args < <(oauth_args "$client_secret")
	auth_source_id="$(find_auth_source_id)"
	if [ -n "$auth_source_id" ]; then
		forgejo_cli admin auth update-oauth --id "$auth_source_id" "${args[@]}"
		printf 'updated Forgejo OAuth auth source: %s (id=%s)\n' "$forgejo_auth_name" "$auth_source_id"
	else
		forgejo_cli admin auth add-oauth "${args[@]}"
		printf 'created Forgejo OAuth auth source: %s\n' "$forgejo_auth_name"
	fi
}

usage() {
	cat <<'EOF'
Usage: forgejo-apply apply

Commands:
  apply    Create or update the Forgejo Kanidm OAuth auth source.
EOF
}

main() {
	local command
	init_vars
	command="${1-apply}"
	case "$command" in
	apply)
		apply_oauth
		;;
	help | --help | -h)
		usage
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
}
