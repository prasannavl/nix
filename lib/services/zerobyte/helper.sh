#!/usr/bin/env bash
set -Eeuo pipefail

init_vars() {
	zerobyte_auto_link_matching_emails="${ZEROBYTE_AUTO_LINK_MATCHING_EMAILS-true}"
	zerobyte_client_id="${ZEROBYTE_CLIENT_ID-}"
	zerobyte_client_secret_file="${ZEROBYTE_CLIENT_SECRET_FILE-}"
	zerobyte_container="${ZEROBYTE_CONTAINER-zerobyte_zerobyte_1}"
	zerobyte_database_path="${ZEROBYTE_DATABASE_PATH-/var/lib/zerobyte/data/zerobyte.db}"
	zerobyte_domain="${ZEROBYTE_DOMAIN-}"
	zerobyte_discovery_endpoint="${ZEROBYTE_DISCOVERY_ENDPOINT-}"
	zerobyte_issuer_url="${ZEROBYTE_ISSUER_URL-}"
	zerobyte_organization_id="${ZEROBYTE_ORGANIZATION_ID-}"
	zerobyte_organization_slug="${ZEROBYTE_ORGANIZATION_SLUG-}"
	zerobyte_provider_id="${ZEROBYTE_PROVIDER_ID-kanidm}"
	zerobyte_wait_seconds="${ZEROBYTE_WAIT_SECONDS-120}"
}

usage() {
	cat <<'EOF'
Usage: zerobyte-apply apply

Commands:
  apply    Create or update the ZeroByte Kanidm OIDC provider.
EOF
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

require_secret_file() {
	require_value zerobyte_client_secret_file "$zerobyte_client_secret_file"
	if [ ! -r "$zerobyte_client_secret_file" ]; then
		printf 'missing readable ZeroByte client secret file: %s\n' "$zerobyte_client_secret_file" >&2
		exit 1
	fi
}

wait_for_container() {
	local elapsed running
	elapsed=0

	while true; do
		if podman container exists "$zerobyte_container" 2>/dev/null; then
			running="$(podman inspect --format '{{.State.Running}}' "$zerobyte_container" 2>/dev/null || true)"
			if [ "$running" = true ]; then
				return 0
			fi
		fi

		if [ "$elapsed" -ge "$zerobyte_wait_seconds" ]; then
			printf 'ZeroByte container did not become ready after %ss: %s\n' "$zerobyte_wait_seconds" "$zerobyte_container" >&2
			exit 1
		fi

		sleep 2
		elapsed=$((elapsed + 2))
	done
}

build_payload() {
	jq -cn \
		--arg autoLinkMatchingEmails "$zerobyte_auto_link_matching_emails" \
		--arg clientId "$zerobyte_client_id" \
		--rawfile clientSecret "$zerobyte_client_secret_file" \
		--arg databasePath "$zerobyte_database_path" \
		--arg domain "$zerobyte_domain" \
		--arg discoveryEndpoint "$zerobyte_discovery_endpoint" \
		--arg issuerUrl "$zerobyte_issuer_url" \
		--arg organizationId "$zerobyte_organization_id" \
		--arg organizationSlug "$zerobyte_organization_slug" \
		--arg providerId "$zerobyte_provider_id" \
		--arg waitSeconds "$zerobyte_wait_seconds" \
		'
		def trim_secret: sub("[\r\n]+$"; "");
		{
			autoLinkMatchingEmails: ($autoLinkMatchingEmails == "true"),
			clientId: $clientId,
			clientSecret: ($clientSecret | trim_secret),
			databasePath: $databasePath,
			domain: $domain,
			discoveryEndpoint: $discoveryEndpoint,
			issuerUrl: $issuerUrl,
			organizationId: $organizationId,
			organizationSlug: $organizationSlug,
			providerId: $providerId,
			waitSeconds: ($waitSeconds | tonumber)
		}
		| if .clientSecret == "" then error("ZeroByte client secret file is empty") else . end
		'
}

run_container_apply() {
	local payload
	payload="$1"

	{
		cat <<'CONTAINER_SH'
set -eu

tmp_dir="$(mktemp -d /tmp/zerobyte-apply.XXXXXX)"
script_path="$tmp_dir/apply.mjs"
cleanup() {
	rm -rf "$tmp_dir"
}
trap cleanup EXIT

cat >"$script_path" <<'ZEROBYTE_APPLY_JS'
import { Database } from "bun:sqlite";
import { existsSync } from "node:fs";
import { randomUUID } from "node:crypto";

const payload = JSON.parse(await new Response(Bun.stdin.stream()).text());

function requireString(name) {
  const value = payload[name];
  if (typeof value !== "string" || value.length === 0) {
    throw new Error(`missing required payload value: ${name}`);
  }
  return value;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function tableExists(db, table) {
  return db
    .query("SELECT 1 AS ok FROM sqlite_master WHERE type = ? AND name = ?")
    .get("table", table) !== null;
}

function openReadyDatabase(path) {
  if (!existsSync(path)) {
    return null;
  }

  const db = new Database(path);
  db.run("PRAGMA foreign_keys = ON");
  db.run("PRAGMA busy_timeout = 5000");

  const requiredTables = ["organization", "sso_provider"];
  if (!requiredTables.every((table) => tableExists(db, table))) {
    db.close();
    return null;
  }

  return db;
}

function resolveOrganization(db) {
  const organizationId = (payload.organizationId || "").trim();
  const organizationSlug = (payload.organizationSlug || "").trim();

  if (organizationId.length > 0) {
    const row = db.query("SELECT id FROM organization WHERE id = ?").get(organizationId);
    if (row === null) {
      throw new Error(`configured ZeroByte organization id does not exist: ${organizationId}`);
    }
    return row.id;
  }

  if (organizationSlug.length > 0) {
    const row = db.query("SELECT id FROM organization WHERE slug = ?").get(organizationSlug);
    if (row === null) {
      throw new Error(`configured ZeroByte organization slug does not exist: ${organizationSlug}`);
    }
    return row.id;
  }

  const rows = db.query("SELECT id, slug FROM organization ORDER BY created_at, id").all();
  if (rows.length === 0) {
    return null;
  }
  if (rows.length > 1) {
    const slugs = rows.map((row) => row.slug).join(", ");
    throw new Error(
      "multiple ZeroByte organizations exist; set ZEROBYTE_ORGANIZATION_ID " +
        `or ZEROBYTE_ORGANIZATION_SLUG explicitly (found: ${slugs})`,
    );
  }
  return rows[0].id;
}

function reconcileProvider(db, organizationId) {
  const providerId = requireString("providerId");
  const clientId = requireString("clientId");
  const clientSecret = requireString("clientSecret");
  const issuerUrl = requireString("issuerUrl");
  const discoveryEndpoint = requireString("discoveryEndpoint");
  const domain = requireString("domain");
  const autoLink = payload.autoLinkMatchingEmails ? 1 : 0;
  const nowMs = Date.now();
  const oidcConfig = JSON.stringify({
    clientId,
    clientSecret,
    discoveryEndpoint,
    scopes: ["openid", "email", "profile"],
  });

  const existing = db
    .query(`
      SELECT
        id,
        organization_id,
        user_id,
        issuer,
        domain,
        auto_link_matching_emails,
        oidc_config,
        saml_config
      FROM sso_provider
      WHERE provider_id = ?
    `)
    .get(providerId);

  if (
    existing !== null &&
    existing.organization_id === organizationId &&
    existing.user_id === null &&
    existing.issuer === issuerUrl &&
    existing.domain === domain &&
    Number(existing.auto_link_matching_emails) === autoLink &&
    existing.oidc_config === oidcConfig &&
    existing.saml_config === null
  ) {
    return "unchanged";
  }

  const providerRowId = existing === null ? randomUUID() : existing.id;
  db.query(`
    INSERT INTO sso_provider (
      id,
      provider_id,
      organization_id,
      user_id,
      issuer,
      domain,
      auto_link_matching_emails,
      oidc_config,
      saml_config,
      created_at,
      updated_at
    ) VALUES (?, ?, ?, NULL, ?, ?, ?, ?, NULL, ?, ?)
    ON CONFLICT(provider_id) DO UPDATE SET
      organization_id = excluded.organization_id,
      user_id = NULL,
      issuer = excluded.issuer,
      domain = excluded.domain,
      auto_link_matching_emails = excluded.auto_link_matching_emails,
      oidc_config = excluded.oidc_config,
      saml_config = NULL,
      updated_at = excluded.updated_at
  `).run(
    providerRowId,
    providerId,
    organizationId,
    issuerUrl,
    domain,
    autoLink,
    oidcConfig,
    nowMs,
    nowMs,
  );

  return existing === null ? "created" : "updated";
}

const databasePath = requireString("databasePath");
const waitSeconds = Number(payload.waitSeconds || 120);
const deadline = Date.now() + waitSeconds * 1000;
let lastError = "";

while (true) {
  let db = null;
  try {
    db = openReadyDatabase(databasePath);
    if (db !== null) {
      const organizationId = resolveOrganization(db);
      if (organizationId === null) {
        console.log("ZeroByte has no organization yet; skipping SSO provider reconciliation");
        process.exit(0);
      }
      const result = reconcileProvider(db, organizationId);
      console.log(`${result} ZeroByte SSO provider ${payload.providerId} for organization ${organizationId}`);
      process.exit(0);
    }
    lastError = "database or required tables are not ready";
  } catch (error) {
    lastError = error instanceof Error ? error.message : String(error);
    if (
      lastError.includes("multiple ZeroByte organizations exist") ||
      lastError.includes("configured ZeroByte organization")
    ) {
      throw error;
    }
  } finally {
    if (db !== null) {
      db.close();
    }
  }

  if (Date.now() >= deadline) {
    throw new Error(
      `ZeroByte database did not become ready for SSO reconciliation after ${waitSeconds}s: ${lastError}`,
    );
  }
  await sleep(2000);
}
ZEROBYTE_APPLY_JS
bun "$script_path" <<'ZEROBYTE_APPLY_PAYLOAD'
CONTAINER_SH
		printf '%s\n' "$payload"
		cat <<'CONTAINER_SH'
ZEROBYTE_APPLY_PAYLOAD
CONTAINER_SH
	} | podman exec -i "$zerobyte_container" sh
}

apply_sso() {
	local payload

	require_value zerobyte_client_id "$zerobyte_client_id"
	require_value zerobyte_container "$zerobyte_container"
	require_value zerobyte_database_path "$zerobyte_database_path"
	require_value zerobyte_domain "$zerobyte_domain"
	require_value zerobyte_discovery_endpoint "$zerobyte_discovery_endpoint"
	require_value zerobyte_issuer_url "$zerobyte_issuer_url"
	require_value zerobyte_provider_id "$zerobyte_provider_id"
	require_secret_file

	wait_for_container
	payload="$(build_payload)"
	run_container_apply "$payload"
}

main() {
	local command
	init_vars
	command="${1-apply}"
	case "$command" in
	apply)
		apply_sso
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
