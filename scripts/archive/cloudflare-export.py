#!/usr/bin/env python3
import argparse
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed
from copy import deepcopy
from email.parser import BytesParser
from email.policy import default
from pathlib import Path

import tomllib


REPO_ROOT = Path(__file__).resolve().parent.parent.parent
IDENTITY = Path(os.environ.get("AGE_KEY_FILE", str(Path.home() / ".ssh" / "id_ed25519")))
TF_CLOUDFLARE_ROOT = REPO_ROOT / "data/secrets/tf/cloudflare"
API_TOKEN_CANDIDATES = [
    REPO_ROOT / "data/secrets/cloudflare/api-token-readall.key.age",
    REPO_ROOT / "data/secrets/cloudflare/api-token.key.age",
]
ACCOUNT_ID_PATH = REPO_ROOT / "data/secrets/cloudflare/r2-account-id.key.age"
CLOUDFLARE_APPS_ROOT = REPO_ROOT / "pkgs/cloudflare-apps"
TMP_DIR = Path(tempfile.mkdtemp(prefix="cf-export."))
ZONE_GROUPS = ("main", "stage", "archive", "inactive")
LEGACY_GENERATED_DIR = TF_CLOUDFLARE_ROOT / "generated"
SECURITY_SETTING_IDS = {
    "always_use_https",
    "automatic_https_rewrites",
    "browser_check",
    "challenge_ttl",
    "ciphers",
    "min_tls_version",
    "opportunistic_encryption",
    "replace_insecure_js",
    "security_level",
    "ssl",
    "tls_1_2_only",
    "tls_1_3",
    "tls_client_auth",
    "waf",
}
KNOWN_DEFAULT_ZONE_SETTINGS = {
    "development_mode": "off",
    "ipv6": "on",
    "minify": {
        "css": "off",
        "html": "off",
        "js": "off",
    },
}
ACCESS_IDENTITY_PROVIDER_CONFIG_KEYS = {
    "apps_domain",
    "attributes",
    "auth_url",
    "authorization_server_id",
    "centrify_account",
    "centrify_app_id",
    "certs_url",
    "claims",
    "client_id",
    "client_secret",
    "conditional_access_enabled",
    "directory_id",
    "email_attribute_name",
    "email_claim_name",
    "header_attributes",
    "idp_public_certs",
    "issuer_url",
    "okta_account",
    "onelogin_account",
    "ping_env_id",
    "pkce_enabled",
    "prompt",
    "scopes",
    "sign_request",
    "sso_target_url",
    "support_groups",
    "token_url",
}
ACCESS_IDENTITY_PROVIDER_SCIM_KEYS = {
    "enabled",
    "identity_update_behavior",
    "seat_deprovision",
    "user_deprovision",
}
ACCESS_POLICY_KEYS = {
    "name",
    "decision",
    "include",
    "exclude",
    "require",
    "session_duration",
    "approval_required",
    "approval_groups",
    "connection_rules",
    "isolation_required",
    "mfa_config",
    "purpose_justification_prompt",
    "purpose_justification_required",
}
ACCESS_APPLICATION_KEYS = {
    "allow_authenticate_via_warp",
    "allow_iframe",
    "allowed_idps",
    "app_launcher_logo_url",
    "app_launcher_visible",
    "auto_redirect_to_identity",
    "bg_color",
    "cors_headers",
    "custom_deny_message",
    "custom_deny_url",
    "custom_non_identity_deny_url",
    "custom_pages",
    "destinations",
    "domain",
    "enable_binding_cookie",
    "footer_links",
    "header_bg_color",
    "http_only_cookie_attribute",
    "landing_page_design",
    "logo_url",
    "name",
    "options_preflight_bypass",
    "path_cookie_attribute",
    "read_service_tokens_from_header",
    "same_site_cookie_attribute",
    "self_hosted_domains",
    "service_auth_401_redirect",
    "session_duration",
    "skip_app_launcher_login_page",
    "skip_interstitial",
    "tags",
    "target_criteria",
    "type",
}
TUNNEL_ORIGIN_REQUEST_FIELD_MAP = {
    "caPool": "ca_pool",
    "ca_pool": "ca_pool",
    "connectTimeout": "connect_timeout",
    "connect_timeout": "connect_timeout",
    "disableChunkedEncoding": "disable_chunked_encoding",
    "disable_chunked_encoding": "disable_chunked_encoding",
    "http2Origin": "http2_origin",
    "http2_origin": "http2_origin",
    "httpHostHeader": "http_host_header",
    "http_host_header": "http_host_header",
    "keepAliveConnections": "keep_alive_connections",
    "keep_alive_connections": "keep_alive_connections",
    "keepAliveTimeout": "keep_alive_timeout",
    "keep_alive_timeout": "keep_alive_timeout",
    "matchSNIToHost": "match_sn_ito_host",
    "matchSNItoHost": "match_sn_ito_host",
    "match_sn_ito_host": "match_sn_ito_host",
    "noHappyEyeballs": "no_happy_eyeballs",
    "no_happy_eyeballs": "no_happy_eyeballs",
    "noTLSVerify": "no_tls_verify",
    "no_tls_verify": "no_tls_verify",
    "originServerName": "origin_server_name",
    "origin_server_name": "origin_server_name",
    "proxyType": "proxy_type",
    "proxy_type": "proxy_type",
    "tcpKeepAlive": "tcp_keep_alive",
    "tcp_keep_alive": "tcp_keep_alive",
    "tlsTimeout": "tls_timeout",
    "tls_timeout": "tls_timeout",
}


def log(message: str):
    print(message, file=sys.stderr, flush=True)


def decrypt(path: Path) -> str:
    out = subprocess.check_output(
        ["age", "--decrypt", "-i", str(IDENTITY), str(path)],
        cwd=REPO_ROOT,
    )
    return out.decode().strip()


def resolve_api_token():
    env_token = os.environ.get("CLOUDFLARE_API_TOKEN")
    if env_token and env_token.strip():
        return env_token.strip()
    for path in API_TOKEN_CANDIDATES:
        if path.exists():
            return decrypt(path)
    raise FileNotFoundError("No Cloudflare API token found in env or age-encrypted secrets.")


def resolve_account_id():
    env_account_id = os.environ.get("CLOUDFLARE_ACCOUNT_ID")
    if env_account_id and env_account_id.strip():
        return env_account_id.strip()
    return decrypt(ACCOUNT_ID_PATH)


API_TOKEN = resolve_api_token()
ACCOUNT_ID = resolve_account_id()


def cf_request(url: str, expect_json: bool = True):
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {API_TOKEN}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read()
            if expect_json:
                return {"ok": True, "status": resp.status, "payload": json.loads(body)}
            return {
                "ok": True,
                "status": resp.status,
                "body": body,
                "headers": dict(resp.headers.items()),
            }
    except urllib.error.HTTPError as exc:
        body = exc.read()
        try:
            payload = json.loads(body)
        except Exception:
            payload = {"success": False, "raw": body.decode("utf-8", "replace")}
        return {"ok": False, "status": exc.code, "payload": payload}
    except Exception as exc:
        return {"ok": False, "status": None, "payload": {"success": False, "error": str(exc)}}


def cf_get_json(url: str):
    result = cf_request(url, expect_json=True)
    if not result["ok"]:
        return result["payload"]
    return result["payload"]


def cf_paginate(url: str):
    items = []
    page = 1
    while True:
        sep = "&" if "?" in url else "?"
        payload = cf_get_json(f"{url}{sep}page={page}&per_page=100")
        if not payload.get("success"):
            return payload
        result = payload.get("result")
        if isinstance(result, dict) and "buckets" in result:
            chunk = result.get("buckets", [])
        elif isinstance(result, list):
            chunk = result
        else:
            return result
        items.extend(chunk)
        info = payload.get("result_info") or {}
        if page >= (info.get("total_pages") or 1):
            return items
        page += 1


def serialize_hcl(value, indent=0):
    space = " " * indent
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, list):
        if not value:
            return "[]"
        parts = [serialize_hcl(v, indent + 2) for v in value]
        return "[\n" + "\n".join(f"{space}  {p}," for p in parts) + f"\n{space}]"
    if isinstance(value, dict):
        if not value:
            return "{}"
        lines = []
        for k, v in value.items():
            key = k if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", k) else json.dumps(k)
            lines.append(f"{space}  {key} = {serialize_hcl(v, indent + 2)}")
        return "{\n" + "\n".join(lines) + f"\n{space}}}"
    raise TypeError(f"Unsupported value type: {type(value)!r}")


def write_hcl_vars(path: Path, variables: dict):
    lines = [f"{key} = {serialize_hcl(value)}" for key, value in variables.items()]
    path.write_text("\n\n".join(lines) + "\n")


def write_secret_tfvars(path: Path, variables: dict):
    age_path = path.with_suffix(".tfvars.age")
    if not variables:
        path.unlink(missing_ok=True)
        age_path.unlink(missing_ok=True)
        return None
    path.parent.mkdir(parents=True, exist_ok=True)
    write_hcl_vars(path, variables)
    subprocess.check_call(["./scripts/age-secrets.sh", "encrypt", str(path.relative_to(REPO_ROOT))], cwd=REPO_ROOT)
    path.unlink(missing_ok=True)
    return age_path


def guess_content_type(path: str) -> str:
    if path.endswith((".js", ".mjs", ".ts", ".mts", ".tsx")):
        return "application/javascript+module"
    guessed = mimetypes.guess_type(path)[0]
    return guessed or "text/plain"


def parse_worker_package(script_name: str):
    url = f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/workers/scripts/{script_name}"
    result = cf_request(url, expect_json=False)
    if not result["ok"]:
        return {"error": result["payload"]}
    content_type = result["headers"].get("Content-Type") or result["headers"].get("content-type")
    message = BytesParser(policy=default).parsebytes(
        f"Content-Type: {content_type}\nMIME-Version: 1.0\n\n".encode() + result["body"]
    )
    parts = {}
    for part in message.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if not name:
            continue
        payload = part.get_payload(decode=True) or b""
        parts[name] = payload
    headers = {k.lower(): v for k, v in result["headers"].items()}
    return {"parts": parts, "headers": headers}


def fetch_worker_latest_version(script_name: str):
    deployments = cf_get_json(
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/workers/scripts/{script_name}/deployments"
    )
    if not deployments.get("success"):
        return None
    deployment_items = deployments.get("result", {}).get("deployments", [])
    if not deployment_items:
        return None
    versions = deployment_items[0].get("versions", [])
    if not versions:
        return None
    version_id = versions[0].get("version_id")
    if not version_id:
        return None
    version = cf_get_json(
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/workers/scripts/{script_name}/versions/{version_id}/content/v2"
    )
    if not version.get("success"):
        return None
    return version.get("result")


def mirror_worker_assets(script_name: str, hostname: str):
    assets_dir = CLOUDFLARE_APPS_ROOT / script_name / "assets"
    shutil.rmtree(assets_dir, ignore_errors=True)
    assets_dir.mkdir(parents=True, exist_ok=True)
    log(f"[worker] {script_name}: mirroring assets from https://{hostname}/")
    subprocess.check_call(
        [
            "wget",
            "--mirror",
            "--page-requisites",
            "--no-parent",
            "--no-host-directories",
            "--execute",
            "robots=off",
            f"--directory-prefix={assets_dir}",
            f"https://{hostname}/",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    files = sorted(p for p in assets_dir.rglob("*") if p.is_file())
    return assets_dir, files


def tfvars_age_paths():
    return sorted(TF_CLOUDFLARE_ROOT.rglob("*.tfvars.age"))


def dns_secret_paths():
    paths = {}
    for group in ZONE_GROUPS:
        new_path = TF_CLOUDFLARE_ROOT / "dns" / f"{group}.tfvars.age"
        legacy_path = TF_CLOUDFLARE_ROOT / f"{group}.tfvars.age"
        if new_path.exists():
            paths[group] = new_path
        elif legacy_path.exists():
            paths[group] = legacy_path
    return paths


def load_existing_zone_groups():
    zone_groups = {}
    for group, secret_path in dns_secret_paths().items():
        plaintext = subprocess.check_output(
            ["age", "--decrypt", "-i", str(IDENTITY), str(secret_path)],
            cwd=REPO_ROOT,
        ).decode()
        for zone_name in re.findall(r'"([^"]+)"\s*=\s*\{\s*records\s*=', plaintext):
            zone_groups[zone_name] = group
    return zone_groups


def resource_group_from_zone_names(zone_names, zone_groups):
    groups = {
        zone_groups[zone_name]
        for zone_name in zone_names
        if zone_name in zone_groups
    }
    if len(groups) == 1:
        return next(iter(groups))
    return "account"


def normalize_dns_record(record):
    out = {
        "name": record["name"][:-1] if record["name"].endswith(".") and record["name"] != "@" else record["name"],
        "type": record["type"],
        "ttl": record.get("ttl", 1),
    }
    if "proxied" in record:
        out["proxied"] = record["proxied"]
    if "priority" in record and record["priority"] is not None:
        out["priority"] = record["priority"]
    if record.get("comment"):
        out["comment"] = record["comment"]
    if record.get("tags"):
        out["tags"] = record["tags"]
    if record.get("data"):
        out["data"] = record["data"]
    elif record.get("content") is not None:
        out["content"] = record["content"]
    return out


def normalize_r2_lifecycle_rule(rule):
    out = {
        "id": rule["id"],
        "enabled": rule["enabled"],
        "conditions": {
            "prefix": (rule.get("conditions") or {}).get("prefix", ""),
        },
    }
    abort_transition = rule.get("abortMultipartUploadsTransition")
    if abort_transition:
        condition = abort_transition.get("condition") or {}
        out["abort_multipart_uploads_transition"] = {
            "condition": {
                "type": condition.get("type"),
                "max_age": condition.get("maxAge"),
            }
        }
    delete_transition = rule.get("deleteObjectsTransition")
    if delete_transition:
        condition = delete_transition.get("condition") or {}
        out["delete_objects_transition"] = {
            "condition": {
                key: value
                for key, value in {
                    "type": condition.get("type"),
                    "date": condition.get("date"),
                    "max_age": condition.get("maxAge"),
                }.items()
                if value is not None
            }
        }
    storage_class_transitions = []
    for transition in rule.get("storageClassTransitions", []):
        condition = transition.get("condition") or {}
        storage_class_transitions.append({
            "storage_class": transition.get("storageClass"),
            "condition": {
                key: value
                for key, value in {
                    "type": condition.get("type"),
                    "date": condition.get("date"),
                    "max_age": condition.get("maxAge"),
                }.items()
                if value is not None
            },
        })
    if storage_class_transitions:
        out["storage_class_transitions"] = storage_class_transitions
    return out


def is_modified_setting(setting):
    return setting.get("editable") and setting.get("modified_on") is not None


def normalize_zone_setting(setting):
    return {
        "setting_id": setting["id"],
        "value": setting.get("value"),
    }


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def is_default_r2_lifecycle_rule(rule):
    return (
        rule.get("id") == "Default Multipart Abort Rule"
        and rule.get("enabled") is True
        and (rule.get("conditions") or {}) == {}
        and (rule.get("abortMultipartUploadsTransition") or {}).get("condition", {}) == {
            "maxAge": 604800,
            "type": "Age",
        }
        and not rule.get("deleteObjectsTransition")
        and not rule.get("storageClassTransitions")
    )


def is_default_email_routing_rule(rule):
    actions = rule.get("actions") or []
    matchers = rule.get("matchers") or []
    return actions == [{"type": "drop"}] and matchers in (
        [{"field": "to", "type": "literal", "value": ""}],
        [{"type": "all"}],
    )


def detect_zone_setting_defaults(zone_data):
    observed = defaultdict(set)
    for data in zone_data.values():
        for setting in try_get_list(data.get("settings", {}).get("result")):
            if setting.get("modified_on") is None:
                observed[setting["id"]].add(canonical_json(setting.get("value")))
    defaults = deepcopy(KNOWN_DEFAULT_ZONE_SETTINGS)
    for setting_id, values in observed.items():
        if len(values) == 1:
            defaults.setdefault(setting_id, json.loads(next(iter(values))))
    return defaults


def try_get_list(value):
    return value if isinstance(value, list) else []


def compact_value(value):
    if isinstance(value, dict):
        compacted = {}
        for key, child in value.items():
            normalized = compact_value(child)
            if normalized in (None, {}, []):
                continue
            compacted[key] = normalized
        return compacted
    if isinstance(value, list):
        compacted = [
            normalized
            for item in value
            if (normalized := compact_value(item)) not in (None, {}, [])
        ]
        return compacted
    return value


def compact_access_object(value, preserve_empty_list_keys=()):
    compacted = {}
    for key, child in value.items():
        if key in preserve_empty_list_keys and isinstance(child, list):
            compacted[key] = child
            continue
        normalized = compact_value(child)
        if normalized in (None, {}, []):
            continue
        compacted[key] = normalized
    return compacted


def slugify(value):
    value = re.sub(r"[^a-z0-9]+", "-", str(value).strip().lower())
    value = value.strip("-")
    return value or "item"


def unique_key(base, used_keys, fallback_prefix):
    base = base or fallback_prefix
    candidate = base
    suffix = 2
    while candidate in used_keys:
        candidate = f"{base}-{suffix}"
        suffix += 1
    used_keys.add(candidate)
    return candidate


def build_access_idp_keys(identity_providers):
    used_keys = set()
    key_by_id = {}
    for identity_provider in identity_providers:
        provider_id = identity_provider.get("id")
        if not provider_id:
            continue
        name = (identity_provider.get("name") or "").strip()
        provider_type = identity_provider.get("type") or "identity-provider"
        base = slugify(name or provider_type)
        key_by_id[provider_id] = unique_key(base, used_keys, "identity-provider")
    return key_by_id


def build_access_group_keys(groups):
    used_keys = set()
    key_by_id = {}
    for group in groups:
        group_id = group.get("id")
        if not group_id:
            continue
        base = slugify((group.get("name") or "").strip() or "group")
        key_by_id[group_id] = unique_key(base, used_keys, "group")
    return key_by_id


def build_access_policy_keys(policies):
    used_keys = set()
    key_by_id = {}
    for policy in policies:
        policy_id = policy.get("id")
        if not policy_id:
            continue
        base = slugify((policy.get("name") or "").strip() or policy.get("decision") or "policy")
        key_by_id[policy_id] = unique_key(base, used_keys, "policy")
    return key_by_id


def build_access_application_keys(applications):
    used_keys = set()
    key_by_id = {}
    for application in applications:
        application_id = application.get("id")
        if not application_id:
            continue
        base = slugify(
            (application.get("name") or "").strip()
            or (application.get("domain") or "").strip()
            or next(iter(try_get_list(application.get("self_hosted_domains"))), "")
            or "application"
        )
        key_by_id[application_id] = unique_key(base, used_keys, "application")
    return key_by_id


def normalize_access_rule_operand(key, value, identity_provider_key_by_id, group_key_by_id):
    if key == "login_method" and isinstance(value, dict):
        mapped_id = identity_provider_key_by_id.get(value.get("id"), value.get("id"))
        return merge_dicts(value, {"id": mapped_id}) if mapped_id is not None else dict(value)
    if key == "group" and isinstance(value, dict):
        mapped_id = group_key_by_id.get(value.get("id"), value.get("id"))
        return merge_dicts(value, {"id": mapped_id}) if mapped_id is not None else dict(value)
    if key == "auth_context" and isinstance(value, dict):
        mapped_id = identity_provider_key_by_id.get(
            value.get("identity_provider_id"),
            value.get("identity_provider_id"),
        )
        return (
            merge_dicts(value, {"identity_provider_id": mapped_id})
            if mapped_id is not None
            else dict(value)
        )
    if isinstance(value, dict):
        return dict(value)
    return value


def remap_access_rule_references(rules, identity_provider_key_by_id, group_key_by_id):
    remapped = []
    for rule in try_get_list(rules):
        if not isinstance(rule, dict):
            continue
        updated_rule = {
            key: normalize_access_rule_operand(key, value, identity_provider_key_by_id, group_key_by_id)
            for key, value in rule.items()
        }
        remapped.append(updated_rule)
    return remapped


def merge_dicts(base, overlay):
    merged = dict(base)
    merged.update(overlay)
    return merged


def first_present(mapping, *keys):
    if not isinstance(mapping, dict):
        return None
    for key in keys:
        if key in mapping and mapping[key] is not None:
            return mapping[key]
    return None


def normalize_listish(value):
    if value is None:
        return None
    if isinstance(value, list):
        return value
    return [value]


def build_tunnel_keys(tunnels):
    used_keys = set()
    key_by_id = {}
    for tunnel in sorted(
        tunnels,
        key=lambda item: (
            slugify((item.get("name") or "").strip()),
            item.get("id") or "",
        ),
    ):
        tunnel_id = tunnel.get("id")
        if not tunnel_id:
            continue
        base = slugify((tunnel.get("name") or "").strip() or tunnel_id or "tunnel")
        key_by_id[tunnel_id] = unique_key(base, used_keys, "tunnel")
    return key_by_id


def tunnel_config_source(tunnel):
    config_src = tunnel.get("config_src")
    if config_src in {"cloudflare", "local"}:
        return config_src
    remote_config = tunnel.get("remote_config")
    if remote_config is True:
        return "cloudflare"
    if remote_config is False:
        return "local"
    return None


def normalize_tunnel_access_config(access):
    if not isinstance(access, dict):
        return None
    normalized = compact_value({
        "aud_tag": normalize_listish(first_present(access, "aud_tag", "audTag")),
        "required": first_present(access, "required"),
        "team_name": first_present(access, "team_name", "teamName"),
    })
    if not normalized:
        return None
    if "aud_tag" not in normalized or "team_name" not in normalized:
        return None
    return normalized


def normalize_tunnel_origin_request(origin_request):
    if not isinstance(origin_request, dict):
        return None
    normalized = {}
    for source_key, destination_key in TUNNEL_ORIGIN_REQUEST_FIELD_MAP.items():
        value = first_present(origin_request, source_key)
        if value is not None:
            normalized[destination_key] = value
    access = normalize_tunnel_access_config(first_present(origin_request, "access"))
    if access:
        normalized["access"] = access
    compacted = compact_value(normalized)
    if compacted in (None, {}, []):
        return {}
    return compacted


def normalize_tunnel_ingress_rule(rule):
    if not isinstance(rule, dict):
        return None
    hostname = first_present(rule, "hostname")
    normalized = compact_value({
        "hostname": hostname,
        "path": first_present(rule, "path"),
        "service": first_present(rule, "service"),
    }) or {}
    raw_origin_request = first_present(rule, "origin_request", "originRequest")
    if raw_origin_request is not None:
        normalized["origin_request"] = normalize_tunnel_origin_request(raw_origin_request) or {}
    elif hostname is not None:
        normalized["origin_request"] = {}
    return normalized or None


def normalize_tunnel_config(config_result):
    raw_config = first_present(config_result, "config")
    if raw_config is None and isinstance(config_result, dict):
        raw_config = config_result
    if not isinstance(raw_config, dict):
        return None
    ingress = [
        normalized
        for rule in try_get_list(first_present(raw_config, "ingress"))
        if (normalized := normalize_tunnel_ingress_rule(rule)) is not None
    ]
    normalized = {}
    if ingress:
        normalized["ingress"] = ingress
    origin_request = normalize_tunnel_origin_request(
        first_present(raw_config, "origin_request", "originRequest")
    )
    if origin_request is not None:
        normalized["origin_request"] = origin_request
    return normalized or None


def fetch_tunnel_config(tunnel):
    tunnel_id = tunnel["id"]
    payload = cf_get_json(
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/cfd_tunnel/{tunnel_id}/configurations"
    )
    return tunnel_id, payload


def fetch_tunnel_inventory():
    log("[api] listing cloudflared tunnels")
    tunnels_payload = cf_paginate(
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/cfd_tunnel?is_deleted=false"
    )
    log("[api] listing tunnel routes")
    routes_payload = cf_paginate(
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/teamnet/routes"
    )
    tunnel_configs = {}
    warnings = []

    tunnels = tunnels_payload if isinstance(tunnels_payload, list) else []
    config_candidates = [
        tunnel
        for tunnel in tunnels
        if tunnel_config_source(tunnel) != "local"
    ]
    if config_candidates:
        with ThreadPoolExecutor(max_workers=min(8, max(1, len(config_candidates)))) as executor:
            futures = {
                executor.submit(fetch_tunnel_config, tunnel): tunnel
                for tunnel in config_candidates
            }
            for future in as_completed(futures):
                tunnel = futures[future]
                tunnel_id, payload = future.result()
                if payload.get("success") and payload.get("result") is not None:
                    tunnel_configs[tunnel_id] = payload["result"]
                    continue
                if tunnel_config_source(tunnel) == "cloudflare":
                    warnings.append({
                        "tunnel": tunnel.get("name") or tunnel_id,
                        "config_error": payload,
                    })

    return {
        "tunnels": tunnels,
        "tunnel_routes": routes_payload if isinstance(routes_payload, list) else [],
        "tunnel_configs": tunnel_configs,
        "warnings": warnings,
    }


def build_tunnel_tfvars(tunnel_inventory):
    tunnels = tunnel_inventory.get("tunnels", [])
    tunnel_configs_by_id = tunnel_inventory.get("tunnel_configs", {})
    tunnel_routes = tunnel_inventory.get("tunnel_routes", [])
    tunnel_key_by_id = build_tunnel_keys(tunnels)
    route_map = defaultdict(list)
    warnings = list(tunnel_inventory.get("warnings", []))

    tunnels_tf = {}
    for tunnel in sorted(
        tunnels,
        key=lambda item: tunnel_key_by_id.get(item.get("id"), item.get("id") or ""),
    ):
        tunnel_id = tunnel.get("id")
        tunnel_key = tunnel_key_by_id.get(tunnel_id)
        if not tunnel_id or tunnel_key is None:
            continue
        tunnels_tf[tunnel_key] = compact_value({
            "name": tunnel.get("name") or tunnel_key,
            "config_src": tunnel_config_source(tunnel),
        })

    tunnel_configs_tf = {}
    for tunnel_id, config_result in sorted(tunnel_configs_by_id.items()):
        tunnel_key = tunnel_key_by_id.get(tunnel_id)
        if tunnel_key is None:
            continue
        normalized_config = normalize_tunnel_config(config_result)
        if normalized_config:
            tunnel_configs_tf[tunnel_key] = {"config": normalized_config}
            continue
        warnings.append({
            "tunnel": tunnel_key,
            "warning": "Tunnel config contains no Terraform-supported ingress/origin_request fields",
        })

    for route in tunnel_routes:
        if not isinstance(route, dict):
            continue
        tunnel_id = route.get("tunnel_id")
        tunnel_key = tunnel_key_by_id.get(tunnel_id)
        if tunnel_key is None:
            if tunnel_id and route.get("network"):
                warnings.append({
                    "tunnel_id": tunnel_id,
                    "route": route.get("network"),
                    "warning": "Tunnel route references a tunnel absent from inventory",
                })
            continue
        network = route.get("network")
        if not network:
            continue
        route_map[tunnel_key].append(compact_value({
            "network": network,
            "comment": route.get("comment"),
            "virtual_network_id": route.get("virtual_network_id"),
        }))

    tunnel_routes_tf = {
        tunnel_key: {
            "routes": sorted(routes, key=lambda route: route["network"]),
        }
        for tunnel_key, routes in sorted(route_map.items())
        if routes
    }

    payload = {
        key: value
        for key, value in {
            "tunnels": tunnels_tf,
            "tunnel_configs": tunnel_configs_tf,
            "tunnel_routes": tunnel_routes_tf,
        }.items()
        if value not in ({}, [], None)
    }
    return payload, warnings


def build_certificate_pack_key(pack, used_keys):
    hosts = sorted(try_get_list(pack.get("hosts")))
    host_label = slugify("-".join(hosts) if hosts else "certificate-pack")
    certificate_authority = slugify(pack.get("certificate_authority") or "ca")
    validation_method = slugify(pack.get("validation_method") or "validation")
    base = f"{pack['zone_name']}/certificate-pack/{certificate_authority}-{validation_method}-{host_label}"
    return unique_key(base, used_keys, f"{pack['zone_name']}/certificate-pack")


def normalize_access_rule_list(rules):
    return compact_value(try_get_list(rules))


def normalize_access_policy(policy):
    return compact_access_object({
        key: compact_value(policy.get(key))
        for key in ACCESS_POLICY_KEYS
        if key not in {"include", "exclude", "require", "approval_groups"}
    })


def normalize_access_application_policy(policy, reusable_policy_ids, reusable_policy_key_by_id, identity_provider_key_by_id, group_key_by_id):
    policy_id = policy.get("id")
    if policy_id and policy_id in reusable_policy_ids:
        return compact_value({
            "id": reusable_policy_key_by_id.get(policy_id, policy_id),
            "precedence": policy.get("precedence"),
        })
    return compact_access_object({
        "name": policy.get("name"),
        "decision": policy.get("decision"),
        "include": remap_access_rule_references(policy.get("include"), identity_provider_key_by_id, group_key_by_id),
        "exclude": remap_access_rule_references(policy.get("exclude"), identity_provider_key_by_id, group_key_by_id),
        "require": remap_access_rule_references(policy.get("require"), identity_provider_key_by_id, group_key_by_id),
        "connection_rules": compact_value(policy.get("connection_rules")),
        "precedence": policy.get("precedence"),
    }, preserve_empty_list_keys=("include", "exclude", "require"))


def normalize_access_application(app, reusable_policy_ids, reusable_policy_key_by_id, identity_provider_key_by_id, group_key_by_id):
    normalized = {
        key: compact_value(app.get(key))
        for key in ACCESS_APPLICATION_KEYS
    }
    if normalized.get("destinations"):
        normalized.pop("self_hosted_domains", None)
    normalized["allowed_idps"] = [
        identity_provider_key_by_id.get(idp_id, idp_id)
        for idp_id in try_get_list(app.get("allowed_idps"))
    ]
    normalized["policies"] = [
        normalize_access_application_policy(
            policy,
            reusable_policy_ids,
            reusable_policy_key_by_id,
            identity_provider_key_by_id,
            group_key_by_id,
        )
        for policy in try_get_list(app.get("policies"))
        if normalize_access_application_policy(
            policy,
            reusable_policy_ids,
            reusable_policy_key_by_id,
            identity_provider_key_by_id,
            group_key_by_id,
        )
    ]
    return compact_value(normalized)


def normalize_access_group(group):
    return compact_access_object({
        "name": group.get("name"),
        "include": normalize_access_rule_list(group.get("include")),
        "exclude": normalize_access_rule_list(group.get("exclude")),
        "require": normalize_access_rule_list(group.get("require")),
        "is_default": group.get("is_default"),
    }, preserve_empty_list_keys=("include", "exclude", "require"))


def normalize_access_identity_provider(identity_provider):
    scim_config = {
        key: compact_value(identity_provider.get("scim_config", {}).get(key))
        for key in ACCESS_IDENTITY_PROVIDER_SCIM_KEYS
    }
    if identity_provider.get("type") == "onetimepin":
        scim_config = {}
    return compact_value({
        "name": identity_provider.get("name"),
        "type": identity_provider.get("type"),
        "config": {
            key: compact_value(identity_provider.get("config", {}).get(key))
            for key in ACCESS_IDENTITY_PROVIDER_CONFIG_KEYS
        },
        "scim_config": scim_config,
    })


def parse_args():
    parser = argparse.ArgumentParser(description="Export Cloudflare resources into repo-managed tfvars.")
    parser.add_argument(
        "--only",
        choices=("all", "access", "tunnels"),
        default="all",
        help="Limit export to a single surface. Defaults to exporting all supported Cloudflare resources.",
    )
    return parser.parse_args()


def fetch_access_inventory():
    log("[api] listing access applications")
    access_applications_payload = cf_paginate(
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/access/apps"
    )
    log("[api] listing access policies")
    access_policies_payload = cf_paginate(
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/access/policies"
    )
    log("[api] listing access groups")
    access_groups_payload = cf_paginate(
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/access/groups"
    )
    log("[api] listing access identity providers")
    access_identity_providers_payload = cf_paginate(
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/access/identity_providers"
    )
    return {
        "access_applications": (
            access_applications_payload
            if isinstance(access_applications_payload, list)
            else []
        ),
        "access_policies": (
            access_policies_payload
            if isinstance(access_policies_payload, list)
            else []
        ),
        "access_groups": (
            access_groups_payload
            if isinstance(access_groups_payload, list)
            else []
        ),
        "access_identity_providers": (
            access_identity_providers_payload
            if isinstance(access_identity_providers_payload, list)
            else []
        ),
    }


def build_access_tfvars(access_inventory):
    identity_provider_key_by_id = build_access_idp_keys(access_inventory["access_identity_providers"])
    group_key_by_id = build_access_group_keys(access_inventory["access_groups"])
    policy_key_by_id = build_access_policy_keys(access_inventory["access_policies"])
    application_key_by_id = build_access_application_keys(access_inventory["access_applications"])
    access_policy_ids = {
        policy["id"]
        for policy in access_inventory["access_policies"]
        if policy.get("id")
    }
    payload = {
        "access_identity_providers": {
            identity_provider_key_by_id[identity_provider["id"]]: normalize_access_identity_provider(identity_provider)
            for identity_provider in access_inventory["access_identity_providers"]
            if identity_provider.get("id")
        },
        "access_groups": {
            group_key_by_id[group["id"]]: compact_access_object({
                "name": group.get("name"),
                "include": remap_access_rule_references(group.get("include"), identity_provider_key_by_id, group_key_by_id),
                "exclude": remap_access_rule_references(group.get("exclude"), identity_provider_key_by_id, group_key_by_id),
                "require": remap_access_rule_references(group.get("require"), identity_provider_key_by_id, group_key_by_id),
                "is_default": group.get("is_default"),
            }, preserve_empty_list_keys=("include", "exclude", "require"))
            for group in access_inventory["access_groups"]
            if group.get("id")
        },
        "access_policies": {
            policy_key_by_id[policy["id"]]: compact_access_object({
                "name": policy.get("name"),
                "decision": policy.get("decision"),
                "include": remap_access_rule_references(policy.get("include"), identity_provider_key_by_id, group_key_by_id),
                "exclude": remap_access_rule_references(policy.get("exclude"), identity_provider_key_by_id, group_key_by_id),
                "require": remap_access_rule_references(policy.get("require"), identity_provider_key_by_id, group_key_by_id),
                "session_duration": policy.get("session_duration"),
                "approval_required": policy.get("approval_required"),
                "approval_groups": compact_value(policy.get("approval_groups")),
                "connection_rules": compact_value(policy.get("connection_rules")),
                "isolation_required": policy.get("isolation_required"),
                "mfa_config": compact_value(policy.get("mfa_config")),
                "purpose_justification_prompt": policy.get("purpose_justification_prompt"),
                "purpose_justification_required": policy.get("purpose_justification_required"),
            }, preserve_empty_list_keys=("include", "exclude", "require"))
            for policy in access_inventory["access_policies"]
            if policy.get("id")
        },
        "access_applications": {
            application_key_by_id[application["id"]]: normalize_access_application(
                application,
                access_policy_ids,
                policy_key_by_id,
                identity_provider_key_by_id,
                group_key_by_id,
            )
            for application in access_inventory["access_applications"]
            if application.get("id")
        },
    }
    return {
        key: value
        for key, value in payload.items()
        if value not in ({}, [], None)
    }


def summarize_tunnel_tfvars(tunnel_tf):
    return {
        "tunnels": len(tunnel_tf.get("tunnels", {})),
        "tunnel_configs": len(tunnel_tf.get("tunnel_configs", {})),
        "tunnel_routes": sum(
            len(route_group.get("routes", []))
            for route_group in tunnel_tf.get("tunnel_routes", {}).values()
        ),
    }


def fetch_zone_inventory(zone):
    zone_id = zone["id"]
    zone_name = zone["name"]
    log(f"[zone] {zone_name}: inventory")
    data = {}
    data["dns_records"] = cf_paginate(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dns_records")
    data["dnssec"] = cf_get_json(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/dnssec")
    data["page_rules"] = cf_paginate(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/pagerules")
    data["rulesets"] = cf_paginate(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/rulesets")
    data["workers_routes"] = cf_paginate(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/workers/routes")
    data["settings"] = cf_get_json(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/settings")
    data["universal_ssl"] = cf_get_json(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/ssl/universal/settings")
    data["total_tls"] = cf_get_json(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/acm/total_tls")
    data["authenticated_origin_pulls"] = cf_get_json(
        f"https://api.cloudflare.com/client/v4/zones/{zone_id}/origin_tls_client_auth/settings"
    )
    data["certificate_packs"] = cf_get_json(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/ssl/certificate_packs?status=all")
    data["email_routing_rules"] = cf_paginate(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/email/routing/rules")
    data["email_routing_settings"] = cf_get_json(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/email/routing")
    data["email_routing_dns"] = cf_get_json(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/email/routing/dns")
    data["email_routing_catch_all"] = cf_get_json(f"https://api.cloudflare.com/client/v4/zones/{zone_id}/email/routing/rules/catch_all")
    return zone_name, data


def fetch_r2_bucket_inventory(bucket_name: str):
    data = {}
    base_url = f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/r2/buckets/{bucket_name}"
    data["bucket"] = cf_get_json(base_url)
    data["cors"] = cf_get_json(f"{base_url}/cors")
    data["lifecycle"] = cf_get_json(f"{base_url}/lifecycle")
    data["lock"] = cf_get_json(f"{base_url}/lock")
    data["managed_domain"] = cf_get_json(f"{base_url}/domains/managed")
    data["custom_domains"] = cf_get_json(f"{base_url}/domains/custom")
    data["event_notifications"] = cf_get_json(f"{base_url}/event-notifications")
    data["sippy"] = cf_get_json(f"{base_url}/sippy")
    return bucket_name, data


def split_zone_map_by_group(zone_map, zone_groups):
    grouped = {group: {} for group in ZONE_GROUPS}
    ungrouped = {}
    for zone_name, value in zone_map.items():
        group = zone_groups.get(zone_name)
        if group in grouped:
            grouped[group][zone_name] = value
        else:
            ungrouped[zone_name] = value
    return grouped, ungrouped


def split_keyed_zone_resources_by_group(resources, zone_groups):
    grouped = {group: {} for group in ZONE_GROUPS}
    ungrouped = {}
    for key, value in resources.items():
        group = zone_groups.get(value.get("zone_name"))
        if group in grouped:
            grouped[group][key] = value
        else:
            ungrouped[key] = value
    return grouped, ungrouped


def split_workers_by_group(workers_tf, zone_groups):
    grouped = {group: {} for group in ZONE_GROUPS}
    account = {}
    for worker_name, worker_cfg in workers_tf.items():
        zone_names = [
            route["zone_name"]
            for route in worker_cfg.get("routes", [])
            if route.get("zone_name")
        ] + [
            domain["zone_name"]
            for domain in worker_cfg.get("custom_domains", [])
            if domain.get("zone_name")
        ]
        group = resource_group_from_zone_names(zone_names, zone_groups)
        if group in grouped:
            grouped[group][worker_name] = worker_cfg
        else:
            account[worker_name] = worker_cfg
    return grouped, account


def split_r2_by_group(r2_tf, zone_groups):
    grouped = {group: {} for group in ZONE_GROUPS}
    account = {}
    for bucket_name, bucket_cfg in r2_tf.items():
        zone_names = [
            domain["zone_name"]
            for domain in bucket_cfg.get("custom_domains", [])
            if domain.get("zone_name")
        ]
        group = resource_group_from_zone_names(zone_names, zone_groups)
        if group in grouped:
            grouped[group][bucket_name] = bucket_cfg
        else:
            account[bucket_name] = bucket_cfg
    return grouped, account


def category_path(category: str, filename: str):
    return TF_CLOUDFLARE_ROOT / category / filename


def main():
    args = parse_args()

    if args.only == "access":
        access_inventory = fetch_access_inventory()
        access_tf = build_access_tfvars(access_inventory)
        written_files = []
        access_age_path = write_secret_tfvars(
            category_path("access", "account.tfvars"),
            access_tf,
        )
        if access_age_path is not None:
            written_files.append(str(access_age_path))
        print(json.dumps({
            "mode": "access",
            "generated_tfvars": written_files,
            "access_identity_providers": len(access_tf.get("access_identity_providers", {})),
            "access_groups": len(access_tf.get("access_groups", {})),
            "access_policies": len(access_tf.get("access_policies", {})),
            "access_applications": len(access_tf.get("access_applications", {})),
        }, indent=2))
        return

    if args.only == "tunnels":
        tunnel_inventory = fetch_tunnel_inventory()
        tunnel_tf, tunnel_warnings = build_tunnel_tfvars(tunnel_inventory)
        written_files = []
        tunnels_age_path = write_secret_tfvars(
            category_path("tunnels", "account.tfvars"),
            tunnel_tf,
        )
        if tunnels_age_path is not None:
            written_files.append(str(tunnels_age_path))
        print(json.dumps({
            "mode": "tunnels",
            "generated_tfvars": written_files,
            **summarize_tunnel_tfvars(tunnel_tf),
            "warnings": tunnel_warnings[:20],
        }, indent=2))
        return

    log("[init] loading existing secret zones")
    zone_groups = load_existing_zone_groups()
    log("[api] listing zones")
    zones = cf_paginate("https://api.cloudflare.com/client/v4/zones")
    log("[api] listing workers")
    workers = cf_paginate(f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/workers/scripts")
    log("[api] listing r2 buckets")
    r2_buckets = cf_paginate(f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/r2/buckets")
    log("[api] listing kv namespaces")
    kv_namespaces = cf_paginate(f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/storage/kv/namespaces")
    log("[api] listing email routing destination addresses")
    email_routing_addresses_payload = cf_paginate(
        f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/email/routing/addresses"
    )
    access_inventory = fetch_access_inventory()
    tunnel_inventory = fetch_tunnel_inventory()
    log("[api] listing workers domains")
    workers_domains = cf_paginate(f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/workers/domains")

    if not isinstance(zones, list):
        raise SystemExit(f"Could not list zones: {zones}")
    if not isinstance(workers, list):
        raise SystemExit(f"Could not list workers: {workers}")
    if not isinstance(r2_buckets, list):
        raise SystemExit(f"Could not list R2 buckets: {r2_buckets}")
    if not isinstance(kv_namespaces, list):
        kv_namespaces = []
    if not isinstance(email_routing_addresses_payload, list):
        email_routing_addresses_payload = []
    if not isinstance(workers_domains, list):
        workers_domains = []

    tunnel_tf, tunnel_warnings = build_tunnel_tfvars(tunnel_inventory)

    zone_name_by_id = {zone["id"]: zone["name"] for zone in zones}
    zone_data = {}
    max_workers = min(8, max(1, len(zones)))
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        futures = {executor.submit(fetch_zone_inventory, zone): zone["name"] for zone in zones}
        for future in as_completed(futures):
            zone_name = futures[future]
            zone_name, data = future.result()
            zone_data[zone_name] = data
            log(f"[zone] {zone_name}: done")

    r2_data = {}
    with ThreadPoolExecutor(max_workers=min(4, max(1, len(r2_buckets)))) as executor:
        futures = {
            executor.submit(fetch_r2_bucket_inventory, bucket["name"]): bucket["name"]
            for bucket in r2_buckets
        }
        for future in as_completed(futures):
            bucket_name, data = future.result()
            r2_data[bucket_name] = data
            log(f"[r2] {bucket_name}: done")
    default_zone_settings = detect_zone_setting_defaults(zone_data)
    routes_by_worker = defaultdict(list)
    for zone_name, data in zone_data.items():
        if isinstance(data["workers_routes"], list):
            for route in data["workers_routes"]:
                if route.get("script"):
                    routes_by_worker[route["script"]].append({
                        "zone_name": zone_name,
                        "pattern": route["pattern"],
                    })

    domains_by_worker = defaultdict(list)
    for domain in workers_domains:
        service = domain.get("service")
        if not service:
            continue
        domains_by_worker[service].append({
            "zone_name": domain.get("zone_name"),
            "hostname": domain.get("hostname"),
        })

    CLOUDFLARE_APPS_ROOT.mkdir(parents=True, exist_ok=True)
    workers_tf = {}
    warnings = []

    for worker in workers:
        name = worker["id"]
        log(f"[worker] {name}: package")
        package = parse_worker_package(name)
        if "error" in package:
            warnings.append({"worker": name, "package_error": package["error"]})
            continue
        worker_dir = CLOUDFLARE_APPS_ROOT / name
        worker_dir.mkdir(parents=True, exist_ok=True)
        parts = package["parts"]
        wrangler = {}
        if "wrangler.toml" in parts:
            wrangler = tomllib.loads(parts["wrangler.toml"].decode())
        for part_name, payload in parts.items():
            if part_name == "wrangler.toml":
                continue
            target = worker_dir / part_name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(payload)
        main_module = wrangler.get("main") or package["headers"].get("cf-entrypoint") or next(
            (name for name in parts.keys() if name.endswith((".js", ".mjs", ".ts"))),
            None,
        )
        modules = []
        for part_name in sorted(parts.keys()):
            if part_name == "wrangler.toml":
                continue
            modules.append({
                "name": part_name,
                "content_file": f"../../pkgs/cloudflare-apps/{name}/{part_name}",
                "content_type": guess_content_type(part_name),
            })
        worker_cfg = {
            "main_module": main_module,
            "modules": modules,
        }
        compatibility_date = wrangler.get("compatibility_date") or worker.get("compatibility_date")
        if compatibility_date:
            worker_cfg["compatibility_date"] = compatibility_date
        observability = wrangler.get("unsafe", {}).get("metadata", {}).get("observability")
        if observability:
            worker_cfg["observability"] = observability
        if routes_by_worker.get(name):
            worker_cfg["routes"] = routes_by_worker[name]
        if domains_by_worker.get(name):
            worker_cfg["custom_domains"] = domains_by_worker[name]
        if not modules and worker.get("has_assets"):
            version = fetch_worker_latest_version(name)
            assets_runtime = (
                version.get("resources", {}).get("script_runtime", {}).get("assets", {})
                if version else {}
            )
            if version:
                runtime_compatibility_date = version.get("resources", {}).get("script_runtime", {}).get("compatibility_date")
                if runtime_compatibility_date and not worker_cfg.get("compatibility_date"):
                    worker_cfg["compatibility_date"] = runtime_compatibility_date
            primary_hostname = next(
                (
                    domain["hostname"]
                    for domain in domains_by_worker.get(name, [])
                    if domain.get("hostname")
                ),
                None,
            )
            if primary_hostname:
                _, asset_files = mirror_worker_assets(name, primary_hostname)
                if asset_files:
                    assets_cfg = {
                        "directory": f"../../pkgs/cloudflare-apps/{name}/assets",
                    }
                    if assets_runtime:
                        assets_config = {}
                        if assets_runtime.get("raw_run_worker_first") is not None:
                            assets_config["run_worker_first"] = assets_runtime["raw_run_worker_first"]
                        if assets_runtime.get("html_handling") is not None:
                            assets_config["html_handling"] = assets_runtime["html_handling"]
                        if assets_runtime.get("not_found_handling") is not None:
                            assets_config["not_found_handling"] = assets_runtime["not_found_handling"]
                        if assets_config:
                            assets_cfg["config"] = assets_config
                    worker_cfg["assets"] = assets_cfg
            else:
                warnings.append({
                    "worker": name,
                    "assets_only": True,
                    "warning": "No custom domain available to mirror asset bundle",
                })
        subdomain = cf_get_json(f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/workers/scripts/{name}/subdomain")
        if subdomain.get("success") and subdomain.get("result"):
            result = subdomain["result"]
            worker_cfg["script_subdomain"] = {
                "enabled": result.get("enabled", False),
                "previews_enabled": result.get("previews_enabled", False),
            }
        log(f"[worker] {name}: schedules")
        schedules = cf_get_json(f"https://api.cloudflare.com/client/v4/accounts/{ACCOUNT_ID}/workers/scripts/{name}/schedules")
        if schedules.get("success") and schedules.get("result"):
            if schedules["result"].get("schedules"):
                worker_cfg["cron_triggers"] = [
                    {"cron": sched["cron"]} for sched in schedules["result"]["schedules"]
                ]
        workers_tf[name] = worker_cfg

    zone_dnssec = {}
    page_rules = {}
    rulesets = {}
    zone_settings = {}
    zone_security_settings = {}
    zone_certificate_packs = {}
    zone_universal_ssl_settings = {}
    zone_total_tls = {}
    zone_authenticated_origin_pulls_settings = {}
    email_routing = {}
    worker_domain_cert_ids = {
        domain["cert_id"]
        for domain in workers_domains
        if domain.get("cert_id")
    }
    zone_certificate_pack_keys = set()

    for zone in zones:
        zone_name = zone["name"]
        data = zone_data[zone_name]

        dnssec = data["dnssec"]
        if dnssec.get("success") and dnssec.get("result"):
            result = dnssec["result"]
            zone_dnssec[zone_name] = {
                k: result.get(k)
                for k in ("status", "dnssec_multi_signer", "dnssec_presigned", "dnssec_use_nsec3")
                if result.get(k) is not None
            }

        if isinstance(data["page_rules"], list):
            for index, rule in enumerate(data["page_rules"]):
                page_rules[f"{zone_name}/page-rule/{index}"] = {
                    "zone_name": zone_name,
                    "target": rule["targets"][0]["constraint"]["value"] if rule.get("targets") else rule.get("target"),
                    "actions": rule.get("actions", {}),
                    "priority": rule.get("priority"),
                    "status": rule.get("status"),
                }

        if isinstance(data["rulesets"], list):
            for ruleset in data["rulesets"]:
                rulesets[f"{zone_name}/{ruleset['phase']}/{ruleset['name']}"] = {
                    "zone_name": zone_name,
                    "name": ruleset["name"],
                    "kind": ruleset["kind"],
                    "phase": ruleset["phase"],
                    "description": ruleset.get("description"),
                    "rules": [
                        {
                            k: v
                            for k, v in rule.items()
                            if k
                            in {
                                "action",
                                "action_parameters",
                                "description",
                                "enabled",
                                "expression",
                                "logging",
                                "ratelimit",
                                "ref",
                            }
                            and v is not None
                        }
                        for rule in ruleset.get("rules", [])
                    ],
                }

        if data["settings"].get("success") and isinstance(data["settings"].get("result"), list):
            general_settings = []
            security_settings = []
            for setting in data["settings"]["result"]:
                if not is_modified_setting(setting):
                    continue
                if setting["id"] in default_zone_settings and setting.get("value") == default_zone_settings[setting["id"]]:
                    continue
                normalized = normalize_zone_setting(setting)
                if setting["id"] in SECURITY_SETTING_IDS:
                    security_settings.append(normalized)
                else:
                    general_settings.append(normalized)
            if general_settings:
                zone_settings[zone_name] = {"settings": general_settings}
            if security_settings:
                zone_security_settings[zone_name] = {"settings": security_settings}
        else:
            warnings.append({"zone": zone_name, "settings_error": data["settings"]})

        universal_ssl = data["universal_ssl"].get("result")
        if universal_ssl and universal_ssl.get("enabled") is False:
            zone_universal_ssl_settings[zone_name] = False

        total_tls = data["total_tls"].get("result")
        if total_tls and total_tls.get("enabled") not in (None, False):
            zone_total_tls[zone_name] = {
                key: value
                for key, value in {
                    "enabled": total_tls.get("enabled"),
                    "certificate_authority": total_tls.get("certificate_authority"),
                }.items()
                if value is not None
            }

        authenticated_origin_pulls = data["authenticated_origin_pulls"].get("result")
        if authenticated_origin_pulls and authenticated_origin_pulls.get("enabled") is True:
            zone_authenticated_origin_pulls_settings[zone_name] = True

        certificate_packs_result = data["certificate_packs"].get("result") or []
        for pack in certificate_packs_result:
            if pack.get("type") != "advanced":
                continue
            if pack.get("id") in worker_domain_cert_ids:
                continue
            pack_data = {
                "zone_name": zone_name,
                "type": pack["type"],
                "certificate_authority": pack["certificate_authority"],
                "validation_method": pack["validation_method"],
                "validity_days": pack["validity_days"],
                "hosts": pack.get("hosts"),
                "cloudflare_branding": pack.get("cloudflare_branding"),
            }
            zone_certificate_packs[build_certificate_pack_key(pack_data, zone_certificate_pack_keys)] = pack_data

        email_cfg = {}
        if isinstance(data["email_routing_rules"], list) and data["email_routing_rules"]:
            email_cfg["rules"] = [
                {
                    k: rule.get(k)
                    for k in ("name", "enabled", "priority", "matchers", "actions")
                    if rule.get(k) is not None
                }
                for rule in data["email_routing_rules"]
                if not is_default_email_routing_rule(rule)
            ]
            if not email_cfg["rules"]:
                email_cfg.pop("rules")
        if data["email_routing_catch_all"].get("success") and data["email_routing_catch_all"].get("result"):
            result = data["email_routing_catch_all"]["result"]
            if not is_default_email_routing_rule(result):
                email_cfg["catch_all"] = {
                    k: result.get(k)
                    for k in ("name", "enabled", "matchers", "actions")
                    if result.get(k) is not None
                }
        email_settings = data["email_routing_settings"].get("result") or {}
        if data["email_routing_settings"].get("success") and (
            email_cfg
            or email_settings.get("enabled")
            or email_settings.get("status") not in (None, "unconfigured")
        ):
            email_cfg["settings"] = True
        if (
            data["email_routing_dns"].get("success")
            and email_settings.get("status") == "ready"
        ):
            email_cfg["dns"] = True
        if email_cfg:
            email_routing[zone_name] = email_cfg

    r2_tf = {}
    for bucket in r2_buckets:
        bucket_name = bucket["name"]
        bucket_data = r2_data.get(bucket_name, {})
        bucket_result = bucket_data.get("bucket", {}).get("result") or {}
        bucket_cfg = {}
        for key in ("jurisdiction", "location", "storage_class"):
            if bucket_result.get(key) not in (None, "", "default"):
                bucket_cfg[key] = bucket_result[key]

        cors_result = bucket_data.get("cors", {}).get("result")
        if cors_result and cors_result.get("rules"):
            bucket_cfg["cors"] = {"rules": cors_result["rules"]}

        lifecycle_result = bucket_data.get("lifecycle", {}).get("result")
        if lifecycle_result is not None:
            lifecycle_rules = [
                normalize_r2_lifecycle_rule(rule)
                for rule in lifecycle_result.get("rules", [])
                if not is_default_r2_lifecycle_rule(rule)
            ]
            if lifecycle_rules:
                bucket_cfg["lifecycle"] = {"rules": lifecycle_rules}

        lock_result = bucket_data.get("lock", {}).get("result")
        if lock_result is not None and lock_result.get("rules"):
            bucket_cfg["lock"] = {"rules": lock_result["rules"]}

        managed_domain_result = bucket_data.get("managed_domain", {}).get("result")
        if managed_domain_result is not None and managed_domain_result.get("enabled"):
            bucket_cfg["managed_domain"] = {"enabled": managed_domain_result["enabled"]}

        custom_domains_result = bucket_data.get("custom_domains", {}).get("result") or {}
        custom_domains = []
        for domain in custom_domains_result.get("domains", []):
            zone_name = zone_name_by_id.get(domain.get("zoneId")) or zone_name_by_id.get(domain.get("zone_id"))
            if not zone_name and domain.get("domain"):
                zone_name = next(
                    (
                        candidate
                        for candidate in zone_name_by_id.values()
                        if domain["domain"] == candidate or domain["domain"].endswith(f".{candidate}")
                    ),
                    None,
                )
            if not zone_name:
                warnings.append({
                    "bucket": bucket_name,
                    "custom_domain": domain.get("domain"),
                    "warning": "Could not resolve zone name for R2 custom domain",
                })
                continue
            custom_domains.append({
                "zone_name": zone_name,
                "domain": domain.get("domain"),
                "enabled": domain.get("enabled", True),
                "min_tls": domain.get("minTLS") or domain.get("min_tls"),
                "ciphers": domain.get("ciphers"),
            })
        if custom_domains:
            bucket_cfg["custom_domains"] = custom_domains

        event_result = bucket_data.get("event_notifications", {}).get("result") or {}
        event_notifications = event_result.get("queues") or event_result.get("notifications") or []
        if event_notifications:
            bucket_cfg["event_notifications"] = event_notifications

        sippy_result = bucket_data.get("sippy", {}).get("result")
        if sippy_result is not None and sippy_result.get("enabled"):
            bucket_cfg["sippy"] = {
                key: value
                for key, value in sippy_result.items()
                if key in {"source", "destination"} and value is not None
            }

        r2_tf[bucket_name] = bucket_cfg

    kv_tf = {ns["title"]: {"title": ns["title"]} for ns in kv_namespaces if ns.get("title")}
    email_routing_addresses = sorted({
        address["email"]
        for address in email_routing_addresses_payload
        if address.get("email")
    })
    access_tf = build_access_tfvars(access_inventory)

    written_files = []
    for secret_path in tfvars_age_paths():
        relative = secret_path.relative_to(REPO_ROOT)
        if "generated" in relative.parts:
            secret_path.unlink(missing_ok=True)
            secret_path.with_suffix("").unlink(missing_ok=True)

    account_payload = {
        "cloudflare_account_id": ACCOUNT_ID,
        "email_routing_addresses": email_routing_addresses,
    }
    account_age_path = write_secret_tfvars(
        category_path("account", "account.tfvars"),
        {
            key: value
            for key, value in account_payload.items()
            if value not in ({}, [], None)
        },
    )
    if account_age_path is not None:
        written_files.append(str(account_age_path))

    workers_grouped, workers_account = split_workers_by_group(workers_tf, zone_groups)
    for group, workers_payload in workers_grouped.items():
        age_path = write_secret_tfvars(
            category_path("workers", f"{group}.tfvars"),
            {"workers": workers_payload} if workers_payload else {},
        )
        if age_path is not None:
            written_files.append(str(age_path))
    workers_account_path = write_secret_tfvars(
        category_path("workers", "main.tfvars"),
        {"workers": workers_account} if workers_account else {},
    )
    if workers_account_path is not None:
        written_files.append(str(workers_account_path))

    r2_grouped, r2_account = split_r2_by_group(r2_tf, zone_groups)
    for group, r2_payload in r2_grouped.items():
        age_path = write_secret_tfvars(
            category_path("r2", f"{group}.tfvars"),
            {"r2_buckets": r2_payload} if r2_payload else {},
        )
        if age_path is not None:
            written_files.append(str(age_path))
    r2_account_path = write_secret_tfvars(
        category_path("r2", "main.tfvars"),
        {"r2_buckets": r2_account} if r2_account else {},
    )
    if r2_account_path is not None:
        written_files.append(str(r2_account_path))

    kv_age_path = write_secret_tfvars(
        category_path("kv", "account.tfvars"),
        {"workers_kv_namespaces": kv_tf} if kv_tf else {},
    )
    if kv_age_path is not None:
        written_files.append(str(kv_age_path))

    access_age_path = write_secret_tfvars(
        category_path("access", "account.tfvars"),
        access_tf,
    )
    if access_age_path is not None:
        written_files.append(str(access_age_path))

    tunnels_age_path = write_secret_tfvars(
        category_path("tunnels", "account.tfvars"),
        tunnel_tf,
    )
    if tunnels_age_path is not None:
        written_files.append(str(tunnels_age_path))

    zone_dnssec_grouped, zone_dnssec_ungrouped = split_zone_map_by_group(zone_dnssec, zone_groups)
    zone_settings_grouped, zone_settings_ungrouped = split_zone_map_by_group(zone_settings, zone_groups)
    zone_security_grouped, zone_security_ungrouped = split_zone_map_by_group(zone_security_settings, zone_groups)
    universal_ssl_grouped, universal_ssl_ungrouped = split_zone_map_by_group(zone_universal_ssl_settings, zone_groups)
    total_tls_grouped, total_tls_ungrouped = split_zone_map_by_group(zone_total_tls, zone_groups)
    auth_origin_grouped, auth_origin_ungrouped = split_zone_map_by_group(
        zone_authenticated_origin_pulls_settings,
        zone_groups,
    )
    email_grouped, email_ungrouped = split_zone_map_by_group(email_routing, zone_groups)
    rulesets_grouped, rulesets_ungrouped = split_keyed_zone_resources_by_group(rulesets, zone_groups)
    page_rules_grouped, page_rules_ungrouped = split_keyed_zone_resources_by_group(page_rules, zone_groups)
    certificate_packs_grouped, certificate_packs_ungrouped = split_keyed_zone_resources_by_group(
        zone_certificate_packs,
        zone_groups,
    )

    for group in ZONE_GROUPS:
        zone_security_payload = {
            "zone_security_settings": zone_security_grouped[group],
            "zone_certificate_packs": certificate_packs_grouped[group],
            "zone_universal_ssl_settings": universal_ssl_grouped[group],
            "zone_total_tls": total_tls_grouped[group],
            "zone_authenticated_origin_pulls_settings": auth_origin_grouped[group],
        }
        zone_category_payloads = {
            ("zone-dnssec", f"{group}.tfvars"): {"zone_dnssec": zone_dnssec_grouped[group]},
            ("zone-settings", f"{group}.tfvars"): {"zone_settings": zone_settings_grouped[group]},
            ("zone-security", f"{group}.tfvars"): zone_security_payload,
            ("rulesets", f"{group}.tfvars"): {"rulesets": rulesets_grouped[group]},
            ("page-rules", f"{group}.tfvars"): {"page_rules": page_rules_grouped[group]},
            ("email-routing", f"{group}.tfvars"): {"email_routing": email_grouped[group]},
        }
        for (category, filename), payload in zone_category_payloads.items():
            age_path = write_secret_tfvars(
                category_path(category, filename),
                {
                    key: value
                    for key, value in payload.items()
                    if value not in ({}, [], None)
                },
            )
            if age_path is not None:
                written_files.append(str(age_path))

    write_secret_tfvars(category_path("dns", "account.tfvars"), {})

    ungrouped_payloads = {
        ("zone-dnssec", "account.tfvars"): {"zone_dnssec": zone_dnssec_ungrouped},
        ("zone-settings", "account.tfvars"): {"zone_settings": zone_settings_ungrouped},
        ("zone-security", "account.tfvars"): {
            "zone_security_settings": zone_security_ungrouped,
            "zone_certificate_packs": certificate_packs_ungrouped,
            "zone_universal_ssl_settings": universal_ssl_ungrouped,
            "zone_total_tls": total_tls_ungrouped,
            "zone_authenticated_origin_pulls_settings": auth_origin_ungrouped,
        },
        ("rulesets", "account.tfvars"): {"rulesets": rulesets_ungrouped},
        ("page-rules", "account.tfvars"): {"page_rules": page_rules_ungrouped},
        ("email-routing", "account.tfvars"): {"email_routing": email_ungrouped},
    }
    for (category, filename), payload in ungrouped_payloads.items():
        age_path = write_secret_tfvars(
            category_path(category, filename),
            {
                key: value
                for key, value in payload.items()
                if value not in ({}, [], None)
            },
        )
        if age_path is not None:
            written_files.append(str(age_path))

    summary = {
        "generated_tfvars": written_files,
        "zones_total": len(zones),
        "workers": len(workers_tf),
        "r2_buckets": len(r2_tf),
        "kv_namespaces": len(kv_tf),
        "access_identity_providers": len(access_tf.get("access_identity_providers", {})),
        "access_groups": len(access_tf.get("access_groups", {})),
        "access_policies": len(access_tf.get("access_policies", {})),
        "access_applications": len(access_tf.get("access_applications", {})),
        "tunnels": len(tunnel_tf.get("tunnels", {})),
        "tunnel_configs": len(tunnel_tf.get("tunnel_configs", {})),
        "tunnel_routes": sum(
            len(route_group.get("routes", []))
            for route_group in tunnel_tf.get("tunnel_routes", {}).values()
        ),
        "rulesets": len(rulesets),
        "page_rules": len(page_rules),
        "zone_settings": len(zone_settings),
        "zone_security_settings": len(zone_security_settings),
        "zone_certificate_packs": len(zone_certificate_packs),
        "zone_universal_ssl_settings": len(zone_universal_ssl_settings),
        "zone_total_tls": len(zone_total_tls),
        "zone_authenticated_origin_pulls_settings": len(zone_authenticated_origin_pulls_settings),
        "email_routing_addresses": len(email_routing_addresses),
        "email_routing_zones": len(email_routing),
        "warnings": (warnings + tunnel_warnings)[:20],
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    try:
        main()
    finally:
        shutil.rmtree(TMP_DIR, ignore_errors=True)
