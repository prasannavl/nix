#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ANSI_RE = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")
DEFAULT_PROJECTS = ["cloudflare-dns", "cloudflare-platform", "cloudflare-apps"]
PROJECT_ENTRY_EXPRESSIONS = {
    "cloudflare-dns": r'''
jsonencode(flatten([
  [
    for zone_name, zone in {
      for name in toset(flatten(concat(
        [keys(var.zones)],
        [keys(var.secret_zones_main)],
        [keys(var.secret_zones_stage)],
        [keys(var.secret_zones_archive)],
        [keys(var.secret_zones_inactive)]
      ))) : name => {
        records = flatten(concat(
          try(var.zones[name].records, []),
          try(var.secret_zones_main[name].records, []),
          try(var.secret_zones_stage[name].records, []),
          try(var.secret_zones_archive[name].records, []),
          try(var.secret_zones_inactive[name].records, [])
        ))
      }
    } : [
      for index, record in zone.records : {
        project = "cloudflare-dns"
        type = "cloudflare_dns_record"
        address = "module.cloudflare_dns.cloudflare_dns_record.record[\"${zone_name}/${upper(record.type)}/${record.name}/${index}\"]"
        index = "${zone_name}/${upper(record.type)}/${record.name}/${index}"
        after = {
          zone_name = zone_name
          name = record.name
          type = upper(record.type)
          content = try(record.content, null)
          data = try(record.data, null)
          priority = try(record.priority, null)
          proxied = try(record.proxied, null)
        }
      }
    ]
  ]
]))
''',
    "cloudflare-platform": r'''
jsonencode(flatten([
  [for key, value in var.access_identity_providers : {
    project = "cloudflare-platform"
    type = "cloudflare_zero_trust_access_identity_provider"
    address = "module.cloudflare_platform.cloudflare_zero_trust_access_identity_provider.identity_provider[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      name = try(value.name, key)
      type = value.type
    }
  }],
  [for key, value in var.access_groups : {
    project = "cloudflare-platform"
    type = "cloudflare_zero_trust_access_group"
    address = "module.cloudflare_platform.cloudflare_zero_trust_access_group.group[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      name = try(value.name, key)
    }
  }],
  [for key, value in var.access_policies : {
    project = "cloudflare-platform"
    type = "cloudflare_zero_trust_access_policy"
    address = "module.cloudflare_platform.cloudflare_zero_trust_access_policy.policy[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      name = try(value.name, key)
      decision = value.decision
    }
  }],
  [for key, value in var.access_applications : {
    project = "cloudflare-platform"
    type = "cloudflare_zero_trust_access_application"
    address = "module.cloudflare_platform.cloudflare_zero_trust_access_application.application[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      name = try(value.name, key)
      type = try(value.type, null)
      domain = try(value.domain, null)
    }
  }],
  [for key, value in var.workers_kv_namespaces : {
    project = "cloudflare-platform"
    type = "cloudflare_workers_kv_namespace"
    address = "module.cloudflare_platform.cloudflare_workers_kv_namespace.namespace[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      title = try(value.title, key)
    }
  }],
  [for email in var.email_routing_addresses : {
    project = "cloudflare-platform"
    type = "cloudflare_email_routing_address"
    address = "module.cloudflare_platform.cloudflare_email_routing_address.address[\"${email}\"]"
    index = email
    after = {
      account_id = var.cloudflare_account_id
      email = email
    }
  }],
  [for key, value in var.tunnels : {
    project = "cloudflare-platform"
    type = "cloudflare_zero_trust_tunnel_cloudflared"
    address = "module.cloudflare_platform.cloudflare_zero_trust_tunnel_cloudflared.tunnel[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      name = try(value.name, key)
    }
  }],
  [for key, value in var.tunnel_configs : {
    project = "cloudflare-platform"
    type = "cloudflare_zero_trust_tunnel_cloudflared_config"
    address = "module.cloudflare_platform.cloudflare_zero_trust_tunnel_cloudflared_config.config[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      hostnames = distinct([
        for ingress in try(value.config.ingress, []) : ingress.hostname
        if try(ingress.hostname, null) != null
      ])
    }
  }],
  [
    for tunnel_key, route_group in var.tunnel_routes : [
      for route in try(route_group.routes, []) : {
        project = "cloudflare-platform"
        type = "cloudflare_zero_trust_tunnel_cloudflared_route"
        address = "module.cloudflare_platform.cloudflare_zero_trust_tunnel_cloudflared_route.route[\"${tunnel_key}/${route.network}\"]"
        index = "${tunnel_key}/${route.network}"
        after = {
          account_id = var.cloudflare_account_id
          network = route.network
        }
      }
    ]
  ],
  [for key, value in var.r2_buckets : {
    project = "cloudflare-platform"
    type = "cloudflare_r2_bucket"
    address = "module.cloudflare_platform.cloudflare_r2_bucket.bucket[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      name = key
      jurisdiction = try(value.jurisdiction, null)
    }
  }],
  [for key, value in {for bucket_name, bucket in var.r2_buckets : bucket_name => bucket if try(bucket.cors, null) != null} : {
    project = "cloudflare-platform"
    type = "cloudflare_r2_bucket_cors"
    address = "module.cloudflare_platform.cloudflare_r2_bucket_cors.cors[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      bucket_name = key
      jurisdiction = try(value.jurisdiction, null)
    }
  }],
  [for key, value in {for bucket_name, bucket in var.r2_buckets : bucket_name => bucket if try(bucket.lifecycle, null) != null} : {
    project = "cloudflare-platform"
    type = "cloudflare_r2_bucket_lifecycle"
    address = "module.cloudflare_platform.cloudflare_r2_bucket_lifecycle.lifecycle[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      bucket_name = key
      jurisdiction = try(value.jurisdiction, null)
    }
  }],
  [for key, value in {for bucket_name, bucket in var.r2_buckets : bucket_name => bucket if try(bucket.lock, null) != null} : {
    project = "cloudflare-platform"
    type = "cloudflare_r2_bucket_lock"
    address = "module.cloudflare_platform.cloudflare_r2_bucket_lock.lock[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      bucket_name = key
      jurisdiction = try(value.jurisdiction, null)
    }
  }],
  [for key, value in {for bucket_name, bucket in var.r2_buckets : bucket_name => bucket if try(bucket.managed_domain, null) != null} : {
    project = "cloudflare-platform"
    type = "cloudflare_r2_managed_domain"
    address = "module.cloudflare_platform.cloudflare_r2_managed_domain.managed_domain[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      bucket_name = key
      jurisdiction = try(value.jurisdiction, null)
    }
  }],
  [
    for bucket_name, bucket in var.r2_buckets : [
      for index, item in try(bucket.custom_domains, []) : {
        project = "cloudflare-platform"
        type = "cloudflare_r2_custom_domain"
        address = "module.cloudflare_platform.cloudflare_r2_custom_domain.custom_domain[\"${bucket_name}/custom-domain/${index}\"]"
        index = "${bucket_name}/custom-domain/${index}"
        after = {
          account_id = var.cloudflare_account_id
          bucket_name = bucket_name
          jurisdiction = try(bucket.jurisdiction, null)
          domain = item.domain
        }
      }
    ]
  ],
  [
    for bucket_name, bucket in var.r2_buckets : [
      for index, item in try(bucket.event_notifications, []) : {
        project = "cloudflare-platform"
        type = "cloudflare_r2_bucket_event_notification"
        address = "module.cloudflare_platform.cloudflare_r2_bucket_event_notification.event_notification[\"${bucket_name}/event-notification/${index}\"]"
        index = "${bucket_name}/event-notification/${index}"
        after = {
          account_id = var.cloudflare_account_id
          bucket_name = bucket_name
          jurisdiction = try(bucket.jurisdiction, null)
          queue_id = item.queue_id
          rules = item.rules
        }
      }
    ]
  ],
  [for key, value in {for bucket_name, bucket in var.r2_buckets : bucket_name => bucket if try(bucket.sippy, null) != null} : {
    project = "cloudflare-platform"
    type = "cloudflare_r2_bucket_sippy"
    address = "module.cloudflare_platform.cloudflare_r2_bucket_sippy.sippy[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      bucket_name = key
      jurisdiction = try(value.jurisdiction, null)
    }
  }],
  [for zone_name, value in var.zone_dnssec : {
    project = "cloudflare-platform"
    type = "cloudflare_zone_dnssec"
    address = "module.cloudflare_platform.cloudflare_zone_dnssec.dnssec[\"${zone_name}\"]"
    index = zone_name
    after = {
      zone_name = zone_name
    }
  }],
  [
    for zone_name, config in var.zone_settings : [
      for setting in try(config.settings, []) : {
        project = "cloudflare-platform"
        type = "cloudflare_zone_setting"
        address = "module.cloudflare_platform.cloudflare_zone_setting.general_setting[\"${zone_name}/${setting.setting_id}\"]"
        index = "${zone_name}/${setting.setting_id}"
        after = {
          zone_name = zone_name
          setting_id = setting.setting_id
        }
      }
    ]
  ],
  [
    for zone_name, config in var.zone_security_settings : [
      for setting in try(config.settings, []) : {
        project = "cloudflare-platform"
        type = "cloudflare_zone_setting"
        address = "module.cloudflare_platform.cloudflare_zone_setting.security_setting[\"${zone_name}/${setting.setting_id}\"]"
        index = "${zone_name}/${setting.setting_id}"
        after = {
          zone_name = zone_name
          setting_id = setting.setting_id
        }
      }
    ]
  ],
  [for key, value in var.zone_certificate_packs : {
    project = "cloudflare-platform"
    type = "cloudflare_certificate_pack"
    address = "module.cloudflare_platform.cloudflare_certificate_pack.certificate_pack[\"${key}\"]"
    index = key
    after = {
      zone_name = value.zone_name
      type = value.type
      hosts = try(value.hosts, null)
      validation_method = value.validation_method
      certificate_authority = value.certificate_authority
    }
  }],
  [for zone_name, value in var.zone_universal_ssl_settings : {
    project = "cloudflare-platform"
    type = "cloudflare_universal_ssl_setting"
    address = "module.cloudflare_platform.cloudflare_universal_ssl_setting.universal_ssl[\"${zone_name}\"]"
    index = zone_name
    after = {
      zone_name = zone_name
    }
  }],
  [for zone_name, value in var.zone_total_tls : {
    project = "cloudflare-platform"
    type = "cloudflare_total_tls"
    address = "module.cloudflare_platform.cloudflare_total_tls.total_tls[\"${zone_name}\"]"
    index = zone_name
    after = {
      zone_name = zone_name
    }
  }],
  [for zone_name, value in var.zone_authenticated_origin_pulls_settings : {
    project = "cloudflare-platform"
    type = "cloudflare_authenticated_origin_pulls_settings"
    address = "module.cloudflare_platform.cloudflare_authenticated_origin_pulls_settings.authenticated_origin_pulls[\"${zone_name}\"]"
    index = zone_name
    after = {
      zone_name = zone_name
    }
  }],
  [for key, value in var.rulesets : {
    project = "cloudflare-platform"
    type = "cloudflare_ruleset"
    address = "module.cloudflare_platform.cloudflare_ruleset.ruleset[\"${key}\"]"
    index = key
    after = {
      account_id = try(value.zone_name, null) == null ? var.cloudflare_account_id : null
      zone_name = try(value.zone_name, null)
      name = value.name
      kind = value.kind
      phase = value.phase
    }
  }],
  [for key, value in var.page_rules : {
    project = "cloudflare-platform"
    type = "cloudflare_page_rule"
    address = "module.cloudflare_platform.cloudflare_page_rule.page_rule[\"${key}\"]"
    index = key
    after = {
      zone_name = value.zone_name
      target = value.target
    }
  }],
  [for zone_name, value in var.tiered_cache : {
    project = "cloudflare-platform"
    type = "cloudflare_tiered_cache"
    address = "module.cloudflare_platform.cloudflare_tiered_cache.tiered_cache[\"${zone_name}\"]"
    index = zone_name
    after = {
      zone_name = zone_name
    }
  }],
  [for zone_name, value in var.regional_tiered_cache : {
    project = "cloudflare-platform"
    type = "cloudflare_regional_tiered_cache"
    address = "module.cloudflare_platform.cloudflare_regional_tiered_cache.regional_tiered_cache[\"${zone_name}\"]"
    index = zone_name
    after = {
      zone_name = zone_name
    }
  }],
  [for zone_name, value in var.zone_cache_reserve : {
    project = "cloudflare-platform"
    type = "cloudflare_zone_cache_reserve"
    address = "module.cloudflare_platform.cloudflare_zone_cache_reserve.cache_reserve[\"${zone_name}\"]"
    index = zone_name
    after = {
      zone_name = zone_name
    }
  }],
  [for zone_name, value in var.zone_cache_variants : {
    project = "cloudflare-platform"
    type = "cloudflare_zone_cache_variants"
    address = "module.cloudflare_platform.cloudflare_zone_cache_variants.cache_variants[\"${zone_name}\"]"
    index = zone_name
    after = {
      zone_name = zone_name
    }
  }],
  [for zone_name, config in {for name, cfg in var.email_routing : name => cfg if try(cfg.settings, false)} : {
    project = "cloudflare-platform"
    type = "cloudflare_email_routing_settings"
    address = "module.cloudflare_platform.cloudflare_email_routing_settings.email_routing_settings[\"${zone_name}\"]"
    index = zone_name
    after = {
      zone_name = zone_name
    }
  }],
  [for zone_name, config in {for name, cfg in var.email_routing : name => cfg if try(cfg.dns, false)} : {
    project = "cloudflare-platform"
    type = "cloudflare_email_routing_dns"
    address = "module.cloudflare_platform.cloudflare_email_routing_dns.email_routing_dns[\"${zone_name}\"]"
    index = zone_name
    after = {
      zone_name = zone_name
    }
  }],
  [
    for zone_name, config in var.email_routing : [
      for index, rule in try(config.rules, []) : {
        project = "cloudflare-platform"
        type = "cloudflare_email_routing_rule"
        address = "module.cloudflare_platform.cloudflare_email_routing_rule.email_routing_rule[\"${zone_name}/email-rule/${index}\"]"
        index = "${zone_name}/email-rule/${index}"
        after = {
          zone_name = zone_name
          name = try(rule.name, null)
          matchers = rule.matchers
          actions = rule.actions
        }
      }
    ]
  ],
  [for zone_name, config in {for name, cfg in var.email_routing : name => cfg if try(cfg.catch_all, null) != null} : {
    project = "cloudflare-platform"
    type = "cloudflare_email_routing_catch_all"
    address = "module.cloudflare_platform.cloudflare_email_routing_catch_all.email_routing_catch_all[\"${zone_name}\"]"
    index = zone_name
    after = {
      zone_name = zone_name
    }
  }]
]))
''',
    "cloudflare-apps": r'''
jsonencode(flatten([
  [for key, value in merge(var.workers_main, var.workers_archive, var.workers_stage, var.workers) : {
    project = "cloudflare-apps"
    type = "cloudflare_worker"
    address = "module.cloudflare_apps.cloudflare_worker.worker[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      name = key
    }
  }],
  [for key, value in merge(var.workers_main, var.workers_archive, var.workers_stage, var.workers) : {
    project = "cloudflare-apps"
    type = "cloudflare_worker_version"
    address = "module.cloudflare_apps.cloudflare_worker_version.version[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
    }
  }],
  [for key, value in merge(var.workers_main, var.workers_archive, var.workers_stage, var.workers) : {
    project = "cloudflare-apps"
    type = "cloudflare_workers_deployment"
    address = "module.cloudflare_apps.cloudflare_workers_deployment.deployment[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
    }
  }],
  [for key, value in {for worker_name, worker in merge(var.workers_main, var.workers_archive, var.workers_stage, var.workers) : worker_name => worker.cron_triggers if length(try(worker.cron_triggers, [])) > 0} : {
    project = "cloudflare-apps"
    type = "cloudflare_workers_cron_trigger"
    address = "module.cloudflare_apps.cloudflare_workers_cron_trigger.cron_trigger[\"${key}\"]"
    index = key
    after = {
      account_id = var.cloudflare_account_id
      script_name = key
    }
  }],
  [
    for worker_name, worker in merge(var.workers_main, var.workers_archive, var.workers_stage, var.workers) : [
      for index, route in try(worker.routes, []) : {
        project = "cloudflare-apps"
        type = "cloudflare_workers_route"
        address = "module.cloudflare_apps.cloudflare_workers_route.route[\"${worker_name}/route/${index}\"]"
        index = "${worker_name}/route/${index}"
        after = {
          zone_name = route.zone_name
          pattern = route.pattern
          script = worker_name
        }
      }
    ]
  ],
  [
    for worker_name, worker in merge(var.workers_main, var.workers_archive, var.workers_stage, var.workers) : [
      for index, domain in try(worker.custom_domains, []) : {
        project = "cloudflare-apps"
        type = "cloudflare_workers_custom_domain"
        address = "module.cloudflare_apps.cloudflare_workers_custom_domain.domain[\"${worker_name}/domain/${index}\"]"
        index = "${worker_name}/domain/${index}"
        after = {
          account_id = var.cloudflare_account_id
          zone_name = domain.zone_name
          hostname = domain.hostname
          service = worker_name
        }
      }
    ]
  ]
]))
''',
}


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub("", text)


def run(
    args: list[str],
    *,
    cwd: Path,
    capture: bool = False,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(
        args,
        cwd=cwd,
        text=True,
        capture_output=capture,
        check=False,
    )
    if check and completed.returncode != 0:
        raise subprocess.CalledProcessError(
            completed.returncode,
            args,
            output=completed.stdout,
            stderr=completed.stderr,
        )
    return completed


def decrypt_age(repo_root: Path, identity: Path, path: Path) -> str:
    return subprocess.check_output(
        ["age", "--decrypt", "-i", str(identity), str(path)],
        cwd=repo_root,
        text=True,
    ).strip()


def resolve_cloudflare_api_token(repo_root: Path, identity: Path) -> str:
    env_token = os.environ.get("CLOUDFLARE_API_TOKEN", "").strip()
    if env_token:
        return env_token

    for path in (
        repo_root / "data/secrets/cloudflare/api-token-readall.key.age",
        repo_root / "data/secrets/cloudflare/api-token.key.age",
    ):
        if path.exists():
            return decrypt_age(repo_root, identity, path)
    raise FileNotFoundError("No Cloudflare API token found in env or age-encrypted secrets.")


def resolve_cloudflare_account_id(repo_root: Path, identity: Path) -> str:
    env_account_id = os.environ.get("CLOUDFLARE_ACCOUNT_ID", "").strip()
    if env_account_id:
        return env_account_id
    return decrypt_age(repo_root, identity, repo_root / "data/secrets/cloudflare/r2-account-id.key.age")


class CloudflareAPI:
    def __init__(self, token: str):
        self.token = token

    def request(self, url: str) -> dict[str, Any]:
        req = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return {"ok": True, "payload": json.loads(resp.read())}
        except urllib.error.HTTPError as exc:
            body = exc.read()
            try:
                payload = json.loads(body)
            except Exception:
                payload = {"success": False, "raw": body.decode("utf-8", "replace")}
            return {"ok": False, "payload": payload}

    def get_json(self, url: str) -> dict[str, Any]:
        result = self.request(url)
        return result["payload"]

    def paginate(self, url: str) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        page = 1
        while True:
            sep = "&" if "?" in url else "?"
            payload = self.get_json(f"{url}{sep}page={page}&per_page=100")
            if not payload.get("success"):
                raise RuntimeError(f"Cloudflare API pagination failed for {url}: {payload}")
            result = payload.get("result")
            if isinstance(result, dict) and "buckets" in result:
                chunk = result.get("buckets", [])
            elif isinstance(result, list):
                chunk = result
            else:
                chunk = []
            items.extend(chunk)
            info = payload.get("result_info") or {}
            if not info or info.get("page", page) >= info.get("total_pages", page):
                if len(chunk) < 100:
                    break
            else:
                page += 1
                continue
            page += 1
        return items

    def try_paginate(self, url: str) -> list[dict[str, Any]]:
        try:
            return self.paginate(url)
        except Exception:
            return []

    def try_result(self, url: str, default: Any) -> Any:
        try:
            payload = self.get_json(url)
        except Exception:
            return default
        return payload.get("result", default)


@dataclass
class ResolverContext:
    account_id: str
    api: CloudflareAPI
    entries: list[dict[str, Any]]

    zone_ids_by_name: dict[str, str] | None = None
    zone_names_by_id: dict[str, str] | None = None
    zone_data: dict[str, dict[str, Any]] | None = None
    account_inventory_loaded: bool = False
    kv_namespaces: list[dict[str, Any]] | None = None
    email_addresses: list[dict[str, Any]] | None = None
    access_inventory: dict[str, list[dict[str, Any]]] | None = None
    tunnels: list[dict[str, Any]] | None = None
    tunnel_routes: list[dict[str, Any]] | None = None
    r2_bucket_data: dict[str, dict[str, Any]] | None = None
    workers: list[dict[str, Any]] | None = None
    worker_by_name: dict[str, dict[str, Any]] | None = None
    worker_domains: list[dict[str, Any]] | None = None
    worker_deployments: dict[str, list[dict[str, Any]]] | None = None

    def ensure_zone_catalog(self) -> None:
        if self.zone_ids_by_name is not None and self.zone_names_by_id is not None:
            return

        self.zone_ids_by_name = {}
        self.zone_names_by_id = {}
        for zone in self.api.paginate("https://api.cloudflare.com/client/v4/zones?status=active"):
            self.zone_ids_by_name[zone["name"]] = zone["id"]
            self.zone_names_by_id[zone["id"]] = zone["name"]

    def zone_id_for_name(self, zone_name: str | None) -> str | None:
        if not zone_name:
            return None
        self.ensure_zone_catalog()
        return self.zone_ids_by_name.get(zone_name)

    def zone_id_for_after(self, after: dict[str, Any]) -> str | None:
        return after.get("zone_id") or self.zone_id_for_name(after.get("zone_name"))

    def ensure_zone_data(self) -> dict[str, dict[str, Any]]:
        if self.zone_data is not None:
            return self.zone_data

        self.ensure_zone_catalog()
        zone_ids = {
            self.zone_id_for_after(entry["after"])
            for entry in self.entries
            if self.zone_id_for_after(entry["after"])
        }
        zone_data: dict[str, dict[str, Any]] = {}
        for zone_id in sorted(zone_ids):
            zone_name = self.zone_names_by_id.get(zone_id)
            base = f"https://api.cloudflare.com/client/v4/zones/{zone_id}"
            zone_data[zone_id] = {
                "zone_id": zone_id,
                "zone_name": zone_name,
                "dns_records": self.api.try_paginate(f"{base}/dns_records"),
                "page_rules": self.api.try_paginate(f"{base}/pagerules"),
                "rulesets": self.api.try_paginate(f"{base}/rulesets"),
                "workers_routes": self.api.try_paginate(f"{base}/workers/routes"),
                "certificate_packs": self.api.try_result(
                    f"{base}/ssl/certificate_packs?status=all",
                    [],
                ),
                "email_rules": self.api.try_paginate(f"{base}/email/routing/rules"),
                "email_catch_all": self.api.try_result(
                    f"{base}/email/routing/rules/catch_all",
                    None,
                ),
            }
        self.zone_data = zone_data
        return zone_data

    def ensure_account_inventory(self) -> None:
        if self.account_inventory_loaded:
            return

        self.kv_namespaces = self.api.try_paginate(
            f"https://api.cloudflare.com/client/v4/accounts/{self.account_id}/storage/kv/namespaces"
        )
        self.email_addresses = self.api.try_paginate(
            f"https://api.cloudflare.com/client/v4/accounts/{self.account_id}/email/routing/addresses"
        )
        self.access_inventory = {
            "identity_providers": self.api.try_paginate(
                f"https://api.cloudflare.com/client/v4/accounts/{self.account_id}/access/identity_providers"
            ),
            "groups": self.api.try_paginate(
                f"https://api.cloudflare.com/client/v4/accounts/{self.account_id}/access/groups"
            ),
            "policies": self.api.try_paginate(
                f"https://api.cloudflare.com/client/v4/accounts/{self.account_id}/access/policies"
            ),
            "applications": self.api.try_paginate(
                f"https://api.cloudflare.com/client/v4/accounts/{self.account_id}/access/apps"
            ),
        }
        self.tunnels = self.api.try_paginate(
            f"https://api.cloudflare.com/client/v4/accounts/{self.account_id}/cfd_tunnel?is_deleted=false"
        )
        self.tunnel_routes = self.api.try_paginate(
            f"https://api.cloudflare.com/client/v4/accounts/{self.account_id}/teamnet/routes"
        )
        self.workers = self.api.try_paginate(
            f"https://api.cloudflare.com/client/v4/accounts/{self.account_id}/workers/scripts"
        )
        self.worker_by_name = {}
        for worker in self.workers:
            if worker.get("name"):
                self.worker_by_name[worker["name"]] = worker
            if worker.get("id"):
                self.worker_by_name[str(worker["id"])] = worker
        self.worker_domains = self.api.try_paginate(
            f"https://api.cloudflare.com/client/v4/accounts/{self.account_id}/workers/domains"
        )
        self.worker_deployments = {}
        self.r2_bucket_data = {}
        self.account_inventory_loaded = True

    def ensure_r2_bucket_data(self, bucket_name: str) -> dict[str, Any]:
        self.ensure_account_inventory()
        if bucket_name in self.r2_bucket_data:
            return self.r2_bucket_data[bucket_name]

        base = f"https://api.cloudflare.com/client/v4/accounts/{self.account_id}/r2/buckets/{bucket_name}"
        data = {
            "custom_domains": self.api.try_result(f"{base}/domains/custom", []),
            "event_notifications": self.api.try_result(f"{base}/event-notifications", []),
        }
        self.r2_bucket_data[bucket_name] = data
        return data

    def ensure_worker_deployments(self, worker_name: str) -> list[dict[str, Any]]:
        self.ensure_account_inventory()
        if worker_name in self.worker_deployments:
            return self.worker_deployments[worker_name]

        payload = self.api.try_result(
            f"https://api.cloudflare.com/client/v4/accounts/{self.account_id}/workers/scripts/{worker_name}/deployments"
        , [])
        if isinstance(payload, dict):
            payload = payload.get("deployments", []) or payload.get("result", [])
        self.worker_deployments[worker_name] = payload
        return payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--apply-from-run-id")
    parser.add_argument("--keep-workspace", action="store_true")
    parser.add_argument("--run-id")
    parser.add_argument("--project", action="append", dest="projects")
    args = parser.parse_args()
    if args.apply_from_run_id and not args.apply:
        parser.error("--apply-from-run-id requires --apply")
    return args


def normalize_json(value: Any) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def unique(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        if not value or value in seen:
            continue
        seen.add(value)
        result.append(value)
    return result


def quote_shell(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def tf_project_provider(project: str) -> str:
    return project.split("-", 1)[0]


def tf_var_secret_paths(repo_root: Path, project: str) -> list[Path]:
    provider = tf_project_provider(project)
    secrets_root = repo_root / "data/secrets/tf"
    paths: list[Path] = []
    seen: set[Path] = set()

    def add_path(path: Path) -> None:
        resolved = path.resolve()
        if resolved in seen or not path.exists():
            return
        seen.add(resolved)
        paths.append(path)

    add_path(secrets_root / f"{provider}.tfvars.age")
    provider_dir = secrets_root / provider
    if provider_dir.is_dir():
        for path in sorted(provider_dir.rglob("*.tfvars.age")):
            add_path(path)

    add_path(secrets_root / f"{project}.tfvars.age")
    project_dir = secrets_root / project
    if project_dir.is_dir():
        for path in sorted(project_dir.rglob("*.tfvars.age")):
            add_path(path)

    return paths


def materialize_tf_var_files(
    repo_root: Path,
    identity: Path,
    project: str,
    temp_root: Path,
) -> list[Path]:
    output_root = temp_root / project
    output_root.mkdir(parents=True, exist_ok=True)
    materialized: list[Path] = []

    for index, source in enumerate(tf_var_secret_paths(repo_root, project)):
        target = output_root / f"{index:03d}-{source.stem}"
        run(
            [
                "age",
                "--decrypt",
                "-i",
                str(identity),
                "-o",
                str(target),
                str(source),
            ],
            cwd=repo_root,
        )
        target.chmod(0o600)
        materialized.append(target)

    return materialized


def tofu_wrapper_import_args(project: str, var_files: list[Path], address: str, candidate: str) -> list[str]:
    args = ["./scripts/nixbot.sh", "tofu", f"-chdir=tf/{project}", "import"]
    args.extend(f"-var-file={path}" for path in var_files)
    args.extend([address, candidate])
    return args


def write_import_script_header(lines: list[str]) -> None:
    lines.extend(
        [
            "mkdir -p tmp",
            'TF_RECOVER_VAR_TMP="$(mktemp -d "tmp/tf-recover-cloudflare-state.XXXXXX")"',
            'cleanup() { rm -rf "${TF_RECOVER_VAR_TMP}"; }',
            "trap cleanup EXIT",
            "",
            'tf_recover_provider_for_project() { printf \'%s\\n\' "${1%%-*}"; }',
            "",
            'tf_recover_emit_var_paths() {',
            '  local project="$1" provider=""',
            '  provider="$(tf_recover_provider_for_project "${project}")"',
            '  [ -f "data/secrets/tf/${provider}.tfvars.age" ] && printf \'%s\\n\' "data/secrets/tf/${provider}.tfvars.age"',
            '  [ -d "data/secrets/tf/${provider}" ] && find "data/secrets/tf/${provider}" -type f -name \'*.tfvars.age\' | sort',
            '  [ -f "data/secrets/tf/${project}.tfvars.age" ] && printf \'%s\\n\' "data/secrets/tf/${project}.tfvars.age"',
            '  [ -d "data/secrets/tf/${project}" ] && find "data/secrets/tf/${project}" -type f -name \'*.tfvars.age\' | sort',
            "}",
            "",
            'tf_recover_import() {',
            '  local project="$1" address="$2" import_id="$3" identity="" source="" out="" index=0',
            '  local -a cmd=(./scripts/nixbot.sh tofu "-chdir=tf/${project}" import)',
            '  identity="${AGE_KEY_FILE:-${HOME}/.ssh/id_ed25519}"',
            '  while IFS= read -r source; do',
            '    [ -n "${source}" ] || continue',
            '    out="${TF_RECOVER_VAR_TMP}/${project}-${index}.tfvars"',
            '    age --decrypt -i "${identity}" -o "${out}" "${source}"',
            '    chmod 600 "${out}"',
            '    cmd+=("-var-file=${out}")',
            '    index=$((index + 1))',
            '  done < <(tf_recover_emit_var_paths "${project}")',
            '  cmd+=("${address}" "${import_id}")',
            '  "${cmd[@]}"',
            "}",
            "",
        ]
    )


def copy_repo_to_workspace(repo_root: Path, workspace_root: Path) -> None:
    run(
        [
            "rsync",
            "-a",
            "--exclude=.git",
            "--exclude=.terraform",
            "--exclude=tmp",
            "--exclude=result",
            "--exclude=.direnv",
            f"{repo_root}/",
            f"{workspace_root}/",
        ],
        cwd=repo_root,
    )


def init_workspace_project(workspace_root: Path, project: str) -> None:
    backend_file = workspace_root / "tf" / project / "backend.tf"
    if backend_file.exists():
        backend_file.unlink()
    run(
        [
            "./scripts/nixbot.sh",
            "tofu",
            f"-chdir=tf/{project}",
            "init",
            "-reconfigure",
            "-lockfile=readonly",
        ],
        cwd=workspace_root,
    )


def decode_console_json(output: str) -> Any:
    cleaned = strip_ansi(output).strip()
    return json.loads(json.loads(cleaned))


def console_eval_json(workspace_root: Path, project: str, expression: str) -> Any:
    completed = subprocess.run(
        ["./scripts/nixbot.sh", "tofu", f"-chdir=tf/{project}", "console"],
        cwd=workspace_root,
        text=True,
        input=expression + "\n",
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        raise subprocess.CalledProcessError(
            completed.returncode,
            completed.args,
            output=completed.stdout,
            stderr=completed.stderr,
        )
    return decode_console_json(completed.stdout)


def build_project_entries(workspace_root: Path, project: str, run_dir: Path) -> list[dict[str, Any]]:
    init_workspace_project(workspace_root, project)
    payload = console_eval_json(workspace_root, project, PROJECT_ENTRY_EXPRESSIONS[project])
    output_path = run_dir / f"{project}.desired.json"
    output_path.write_text(json.dumps(payload, indent=2) + "\n")
    return payload


def load_prior_manifest(repo_root: Path, source_run_id: str) -> list[dict[str, Any]]:
    manifest_path = repo_root / "docs/ai/runs" / source_run_id / "manifest.json"
    if not manifest_path.exists():
        raise FileNotFoundError(f"Manifest not found for prior run: {manifest_path}")

    payload = json.loads(manifest_path.read_text())
    if not isinstance(payload, list):
        raise RuntimeError(f"Prior manifest is not a list: {manifest_path}")
    return payload


def match_by_fields(items: list[dict[str, Any]], expected: dict[str, Any]) -> dict[str, Any] | None:
    for item in items:
        ok = True
        for key, value in expected.items():
            if isinstance(value, (dict, list)):
                if normalize_json(item.get(key)) != normalize_json(value):
                    ok = False
                    break
            elif item.get(key) != value:
                ok = False
                break
        if ok:
            return item
    return None


def normalize_dns_name(zone_name: str, record_name: str | None) -> str | None:
    if record_name is None:
        return None

    name = str(record_name).strip().rstrip(".").lower()
    zone = str(zone_name).strip().rstrip(".").lower()
    if not name or name == "@":
        return zone
    if name == zone or name.endswith(f".{zone}"):
        return name
    return f"{name}.{zone}"


def normalize_dns_content(record_type: str | None, content: str | None) -> str | None:
    if content is None:
        return None

    normalized = str(content).strip().rstrip(".")
    if record_type in {"CNAME", "MX", "NS"}:
        return normalized.lower()
    return normalized


def match_dns_record(live_records: list[dict[str, Any]], after: dict[str, Any]) -> dict[str, Any] | None:
    zone_name = after.get("zone_name")
    expected_type = str(after.get("type") or "").upper()
    expected_name = normalize_dns_name(zone_name, after.get("name"))
    expected_content = normalize_dns_content(expected_type, after.get("content"))
    expected_priority = after.get("priority")
    expected_proxied = after.get("proxied")
    expected_data = after.get("data")

    candidates: list[dict[str, Any]] = []
    for live in live_records:
        live_type = str(live.get("type") or "").upper()
        if live_type != expected_type:
            continue
        if normalize_dns_name(zone_name, live.get("name")) != expected_name:
            continue
        if expected_content is not None:
            live_content = normalize_dns_content(expected_type, live.get("content"))
            if live_content != expected_content:
                continue
        if expected_priority is not None and live.get("priority") != expected_priority:
            continue
        if expected_proxied is not None and live.get("proxied") != expected_proxied:
            continue
        if expected_data is not None and normalize_json(live.get("data")) != normalize_json(expected_data):
            continue
        candidates.append(live)

    if len(candidates) == 1:
        return candidates[0]
    if len(candidates) > 1:
        exact = [
            candidate
            for candidate in candidates
            if candidate.get("ttl") in (1, after.get("ttl"), None)
        ]
        if len(exact) == 1:
            return exact[0]
        return candidates[0]
    return None


def latest_worker_deployment(deployments: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not deployments:
        return None
    return sorted(
        deployments,
        key=lambda item: (item.get("created_on") or "", item.get("id") or ""),
        reverse=True,
    )[0]


def resolve_entry(entry: dict[str, Any], ctx: ResolverContext) -> dict[str, Any]:
    after = dict(entry["after"])
    zone_id = ctx.zone_id_for_after(after)
    if zone_id and "zone_id" not in after:
        after["zone_id"] = zone_id

    result = {
        "project": entry["project"],
        "address": entry["address"],
        "type": entry["type"],
        "status": "resolved",
        "import_candidates": [],
        "note": "",
    }

    if entry["type"] == "cloudflare_dns_record":
        zone = ctx.ensure_zone_data().get(after["zone_id"])
        live = None if zone is None else match_dns_record(zone["dns_records"], after)
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching DNS record found."
            return result
        result["import_candidates"] = [f"{after['zone_id']}/{live['id']}"]
        return result

    if entry["type"] == "cloudflare_workers_kv_namespace":
        ctx.ensure_account_inventory()
        live = match_by_fields(ctx.kv_namespaces or [], {"title": after.get("title")})
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching KV namespace found."
            return result
        result["import_candidates"] = unique([f"{after['account_id']}/{live['id']}", str(live["id"])])
        return result

    if entry["type"] == "cloudflare_email_routing_address":
        ctx.ensure_account_inventory()
        live = match_by_fields(ctx.email_addresses or [], {"email": after.get("email")})
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching Email Routing destination address found."
            return result
        result["import_candidates"] = unique([f"{after['account_id']}/{live['id']}", str(live["id"])])
        return result

    if entry["type"] == "cloudflare_zero_trust_access_identity_provider":
        ctx.ensure_account_inventory()
        live = match_by_fields(
            ctx.access_inventory["identity_providers"],
            {"name": after.get("name"), "type": after.get("type")},
        )
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching Access identity provider found."
            return result
        result["import_candidates"] = unique(
            [
                f"accounts/{after['account_id']}/{live['id']}",
                f"{after['account_id']}/{live['id']}",
                str(live["id"]),
            ]
        )
        return result

    if entry["type"] == "cloudflare_zero_trust_access_group":
        ctx.ensure_account_inventory()
        live = match_by_fields(ctx.access_inventory["groups"], {"name": after.get("name")})
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching Access group found."
            return result
        result["import_candidates"] = unique(
            [
                f"accounts/{after['account_id']}/{live['id']}",
                f"{after['account_id']}/{live['id']}",
                str(live["id"]),
            ]
        )
        return result

    if entry["type"] == "cloudflare_zero_trust_access_policy":
        ctx.ensure_account_inventory()
        live = match_by_fields(
            ctx.access_inventory["policies"],
            {"name": after.get("name"), "decision": after.get("decision")},
        )
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching Access policy found."
            return result
        result["import_candidates"] = unique(
            [
                f"{after['account_id']}/{live['id']}",
                f"accounts/{after['account_id']}/{live['id']}",
                str(live["id"]),
            ]
        )
        return result

    if entry["type"] == "cloudflare_zero_trust_access_application":
        ctx.ensure_account_inventory()
        expected = {"name": after.get("name")}
        if after.get("domain") is not None:
            expected["domain"] = after.get("domain")
        if after.get("type") is not None:
            expected["type"] = after.get("type")
        live = match_by_fields(ctx.access_inventory["applications"], expected)
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching Access application found."
            return result
        result["import_candidates"] = unique(
            [
                f"accounts/{after['account_id']}/{live['id']}",
                f"{after['account_id']}/{live['id']}",
                str(live["id"]),
            ]
        )
        return result

    if entry["type"] == "cloudflare_zero_trust_tunnel_cloudflared":
        ctx.ensure_account_inventory()
        live = match_by_fields(ctx.tunnels or [], {"name": after.get("name")})
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching tunnel found."
            return result
        result["import_candidates"] = [f"{after['account_id']}/{live['id']}"]
        return result

    if entry["type"] == "cloudflare_zero_trust_tunnel_cloudflared_config":
        ctx.ensure_account_inventory()
        tunnel_key = str(entry["index"])
        tunnel_entry = next(
            item
            for item in ctx.entries
            if item["project"] == entry["project"]
            and item["type"] == "cloudflare_zero_trust_tunnel_cloudflared"
            and str(item["index"]) == tunnel_key
        )
        live = match_by_fields(ctx.tunnels or [], {"name": tunnel_entry["after"]["name"]})
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching tunnel found for config import."
            return result
        result["import_candidates"] = [f"{after['account_id']}/{live['id']}"]
        return result

    if entry["type"] == "cloudflare_zero_trust_tunnel_cloudflared_route":
        ctx.ensure_account_inventory()
        tunnel_key = str(entry["index"]).split("/", 1)[0]
        tunnel_entry = next(
            item
            for item in ctx.entries
            if item["project"] == entry["project"]
            and item["type"] == "cloudflare_zero_trust_tunnel_cloudflared"
            and str(item["index"]) == tunnel_key
        )
        tunnel_live = match_by_fields(ctx.tunnels or [], {"name": tunnel_entry["after"]["name"]})
        live = None if tunnel_live is None else match_by_fields(
            ctx.tunnel_routes or [],
            {"tunnel_id": tunnel_live["id"], "network": after.get("network")},
        )
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching tunnel route found."
            return result
        result["import_candidates"] = [f"{after['account_id']}/{live['id']}"]
        return result

    if entry["type"] == "cloudflare_r2_bucket":
        jurisdiction = after.get("jurisdiction") or "default"
        result["import_candidates"] = unique(
            [f"{after['account_id']}/{after['name']}/{jurisdiction}", f"{after['account_id']}/{after['name']}"]
        )
        return result

    if entry["type"] in {
        "cloudflare_r2_bucket_cors",
        "cloudflare_r2_bucket_lifecycle",
        "cloudflare_r2_bucket_lock",
        "cloudflare_r2_bucket_sippy",
    }:
        jurisdiction = after.get("jurisdiction") or "default"
        result["import_candidates"] = unique(
            [
                f"{after['account_id']}/{after['bucket_name']}/{jurisdiction}",
                f"{after['account_id']}/{after['bucket_name']}",
            ]
        )
        return result

    if entry["type"] == "cloudflare_r2_managed_domain":
        result["status"] = "manual"
        result["note"] = "Provider import is not implemented; import the bucket and then run a targeted apply."
        return result

    if entry["type"] == "cloudflare_r2_custom_domain":
        bucket_data = ctx.ensure_r2_bucket_data(after["bucket_name"])
        live = match_by_fields(bucket_data["custom_domains"], {"domain": after.get("domain")})
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching R2 custom domain found."
            return result
        live_id = str(live.get("id") or live.get("domain_id") or "")
        jurisdiction = after.get("jurisdiction") or "default"
        result["import_candidates"] = unique(
            [
                f"{after['account_id']}/{after['bucket_name']}/{live_id}/{jurisdiction}",
                f"{after['account_id']}/{after['bucket_name']}/{live_id}",
                f"{after['account_id']}/{live_id}",
                live_id,
            ]
        )
        return result

    if entry["type"] == "cloudflare_r2_bucket_event_notification":
        bucket_data = ctx.ensure_r2_bucket_data(after["bucket_name"])
        live = match_by_fields(
            bucket_data["event_notifications"],
            {"queue_id": after.get("queue_id"), "rules": after.get("rules")},
        )
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching R2 event notification found."
            return result
        live_id = str(live.get("id") or live.get("queue_id") or "")
        jurisdiction = after.get("jurisdiction") or "default"
        result["import_candidates"] = unique(
            [
                f"{after['account_id']}/{after['bucket_name']}/{live_id}/{jurisdiction}",
                f"{after['account_id']}/{after['bucket_name']}/{live_id}",
                live_id,
            ]
        )
        return result

    if entry["type"] in {
        "cloudflare_zone_dnssec",
        "cloudflare_universal_ssl_setting",
        "cloudflare_total_tls",
        "cloudflare_authenticated_origin_pulls_settings",
        "cloudflare_tiered_cache",
        "cloudflare_regional_tiered_cache",
        "cloudflare_zone_cache_reserve",
        "cloudflare_zone_cache_variants",
        "cloudflare_email_routing_settings",
        "cloudflare_email_routing_dns",
    }:
        result["import_candidates"] = [after["zone_id"]]
        return result

    if entry["type"] == "cloudflare_zone_setting":
        result["import_candidates"] = unique([f"{after['zone_id']}/{after['setting_id']}", after["setting_id"]])
        return result

    if entry["type"] == "cloudflare_certificate_pack":
        zone = ctx.ensure_zone_data().get(after["zone_id"])
        live = None
        if zone is not None:
            for pack in zone["certificate_packs"]:
                if pack.get("type") != after.get("type"):
                    continue
                if pack.get("validation_method") != after.get("validation_method"):
                    continue
                if pack.get("certificate_authority") != after.get("certificate_authority"):
                    continue
                if sorted(pack.get("hosts") or []) != sorted(after.get("hosts") or []):
                    continue
                live = pack
                break
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching certificate pack found."
            return result
        result["import_candidates"] = unique([f"{after['zone_id']}/{live['id']}", str(live["id"])])
        return result

    if entry["type"] == "cloudflare_ruleset":
        if after.get("zone_id"):
            live = match_by_fields(
                ctx.ensure_zone_data().get(after["zone_id"], {}).get("rulesets", []),
                {"name": after.get("name"), "kind": after.get("kind"), "phase": after.get("phase")},
            )
            scope_id = after["zone_id"]
        else:
            live = match_by_fields(
                ctx.api.paginate(
                    f"https://api.cloudflare.com/client/v4/accounts/{after['account_id']}/rulesets"
                ),
                {"name": after.get("name"), "kind": after.get("kind"), "phase": after.get("phase")},
            )
            scope_id = after["account_id"]
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching ruleset found."
            return result
        result["import_candidates"] = unique([f"{scope_id}/{live['id']}", str(live["id"])])
        return result

    if entry["type"] == "cloudflare_page_rule":
        zone = ctx.ensure_zone_data().get(after["zone_id"])
        live = None if zone is None else match_by_fields(zone["page_rules"], {"target": after.get("target")})
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching page rule found."
            return result
        result["import_candidates"] = unique([f"{after['zone_id']}/{live['id']}", str(live["id"])])
        return result

    if entry["type"] == "cloudflare_email_routing_rule":
        zone = ctx.ensure_zone_data().get(after["zone_id"])
        live = None if zone is None else match_by_fields(
            zone["email_rules"],
            {
                "name": after.get("name"),
                "matchers": after.get("matchers"),
                "actions": after.get("actions"),
            },
        )
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching Email Routing rule found."
            return result
        result["import_candidates"] = unique([f"{after['zone_id']}/{live['id']}", str(live["id"])])
        return result

    if entry["type"] == "cloudflare_email_routing_catch_all":
        zone = ctx.ensure_zone_data().get(after["zone_id"])
        live = None if zone is None else zone.get("email_catch_all")
        if not live:
            result["status"] = "missing"
            result["note"] = "No Email Routing catch-all rule found."
            return result
        live_id = str(live.get("id") or "catch_all")
        result["import_candidates"] = unique([f"{after['zone_id']}/{live_id}", live_id])
        return result

    if entry["type"] == "cloudflare_worker":
        ctx.ensure_account_inventory()
        live = ctx.worker_by_name.get(after["name"])
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching Worker script found."
            return result
        live_id = str(live.get("id") or after["name"])
        result["import_candidates"] = unique(
            [f"{after['account_id']}/{after['name']}", f"{after['account_id']}/{live_id}", live_id]
        )
        return result

    if entry["type"] == "cloudflare_worker_version":
        ctx.ensure_account_inventory()
        worker_entry = next(
            item
            for item in ctx.entries
            if item["project"] == entry["project"]
            and item["type"] == "cloudflare_worker"
            and str(item["index"]) == str(entry["index"])
        )
        worker_name = worker_entry["after"]["name"]
        worker = ctx.worker_by_name.get(worker_name)
        deployments = ctx.ensure_worker_deployments(worker_name)
        deployment = latest_worker_deployment(deployments)
        if worker is None or deployment is None or not (deployment.get("versions") or []):
            result["status"] = "missing"
            result["note"] = "No deployed Worker version found."
            return result
        version_id = deployment["versions"][0].get("version_id")
        worker_id = str(worker.get("id") or worker_name)
        result["import_candidates"] = unique(
            [f"{after['account_id']}/{worker_id}/{version_id}", f"{after['account_id']}/{worker_name}/{version_id}"]
        )
        result["note"] = "Imported Worker versions may need one follow-up state-only normalization from content_base64 back to content_file."
        return result

    if entry["type"] == "cloudflare_workers_deployment":
        ctx.ensure_account_inventory()
        worker_entry = next(
            item
            for item in ctx.entries
            if item["project"] == entry["project"]
            and item["type"] == "cloudflare_worker"
            and str(item["index"]) == str(entry["index"])
        )
        worker_name = worker_entry["after"]["name"]
        worker = ctx.worker_by_name.get(worker_name)
        deployment = latest_worker_deployment(ctx.ensure_worker_deployments(worker_name))
        if deployment is None:
            result["status"] = "missing"
            result["note"] = "No Worker deployment found."
            return result
        worker_id = str((worker or {}).get("id") or worker_name)
        deployment_id = str(deployment["id"])
        result["import_candidates"] = unique(
            [
                f"{after['account_id']}/{worker_name}/{deployment_id}",
                f"{after['account_id']}/{worker_id}/{deployment_id}",
                deployment_id,
            ]
        )
        return result

    if entry["type"] == "cloudflare_workers_cron_trigger":
        result["import_candidates"] = unique([f"{after['account_id']}/{after['script_name']}", after["script_name"]])
        return result

    if entry["type"] == "cloudflare_workers_route":
        zone = ctx.ensure_zone_data().get(after["zone_id"])
        live = None if zone is None else match_by_fields(
            zone["workers_routes"],
            {"pattern": after.get("pattern"), "script": after.get("script")},
        )
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching Workers route found."
            return result
        result["import_candidates"] = unique([f"{after['zone_id']}/{live['id']}", str(live["id"])])
        return result

    if entry["type"] == "cloudflare_workers_custom_domain":
        ctx.ensure_account_inventory()
        live = match_by_fields(
            ctx.worker_domains or [],
            {"hostname": after.get("hostname"), "service": after.get("service")},
        )
        if live is None:
            result["status"] = "missing"
            result["note"] = "No matching Workers custom domain found."
            return result
        live_id = str(live.get("id") or live.get("domain_id") or live.get("hostname"))
        result["import_candidates"] = unique(
            [f"{after['account_id']}/{live_id}", f"{after['zone_id']}/{live_id}", live_id]
        )
        return result

    result["status"] = "unsupported"
    result["note"] = f"No resolver implemented for {entry['type']}."
    return result


def build_manifest(entries: list[dict[str, Any]], ctx: ResolverContext) -> list[dict[str, Any]]:
    return [resolve_entry(entry, ctx) for entry in entries]


def write_command_file(repo_root: Path, manifest: list[dict[str, Any]], output_path: Path) -> None:
    lines = [
        "#!/usr/bin/env bash",
        "set -Eeuo pipefail",
        "",
        f"cd {quote_shell(str(repo_root))}",
        "",
    ]
    write_import_script_header(lines)
    for item in manifest:
        lines.append(f"# {item['address']} [{item['status']}]")
        if item["status"] != "resolved":
            lines.append(f"# {item.get('note') or 'unresolved'}")
            lines.append("")
            continue
        lines.append(
            " ".join(
                [
                    "tf_recover_import",
                    quote_shell(item["project"]),
                    quote_shell(item["address"]),
                    quote_shell(item["import_candidates"][0]),
                ]
            )
        )
        lines.append("")
    output_path.write_text("\n".join(lines) + "\n")
    output_path.chmod(0o755)


def existing_state_addresses(repo_root: Path, project: str) -> set[str]:
    completed = run(
        ["./scripts/nixbot.sh", "tofu", f"-chdir=tf/{project}", "state", "list"],
        cwd=repo_root,
        capture=True,
        check=False,
    )
    if completed.returncode != 0:
        return set()
    return {line.strip() for line in strip_ansi(completed.stdout).splitlines() if line.strip()}


def snapshot_state(repo_root: Path, project: str, run_dir: Path) -> None:
    completed = run(
        ["./scripts/nixbot.sh", "tofu", f"-chdir=tf/{project}", "state", "pull"],
        cwd=repo_root,
        capture=True,
        check=False,
    )
    if completed.returncode == 0 and completed.stdout.strip():
        (run_dir / f"{project}.state-pull.json").write_text(completed.stdout)
    else:
        (run_dir / f"{project}.state-pull.error.txt").write_text(
            strip_ansi((completed.stderr or completed.stdout or "").strip()) + "\n"
        )


def import_manifest(repo_root: Path, manifest: list[dict[str, Any]], run_dir: Path, identity: Path) -> None:
    by_project: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for item in manifest:
        by_project[item["project"]].append(item)

    failures: list[str] = []
    temp_root = Path(tempfile.mkdtemp(prefix="tf-recover-import-vars-", dir=str(repo_root / "tmp")))
    try:
        for project, items in by_project.items():
            run(
                ["./scripts/nixbot.sh", "tofu", f"-chdir=tf/{project}", "init", "-lockfile=readonly"],
                cwd=repo_root,
            )
            var_files = materialize_tf_var_files(repo_root, identity, project, temp_root)
            snapshot_state(repo_root, project, run_dir)
            existing = existing_state_addresses(repo_root, project)

            for item in items:
                if item["status"] == "manual":
                    item["applied_status"] = "manual"
                    continue
                if item["status"] != "resolved":
                    failures.append(f"{item['address']}: {item['status']}")
                    continue
                if item["address"] in existing:
                    item["applied_status"] = "skipped-existing"
                    continue

                imported = False
                last_error = ""
                for candidate in item["import_candidates"]:
                    completed = run(
                        tofu_wrapper_import_args(project, var_files, item["address"], candidate),
                        cwd=repo_root,
                        capture=True,
                        check=False,
                    )
                    if completed.returncode == 0:
                        imported = True
                        item["applied_status"] = "imported"
                        item["applied_candidate"] = candidate
                        break
                    last_error = strip_ansi((completed.stderr or completed.stdout or "").strip())

                if not imported:
                    item["applied_status"] = "failed"
                    item["applied_error"] = last_error
                    failures.append(f"{item['address']}: import failed")

            for plan_kind, extra_args in (
                ("refresh-only", ["plan", "-refresh-only", "-input=false"]),
                ("plan", ["plan", "-input=false"]),
            ):
                completed = run(
                    ["./scripts/nixbot.sh", "tofu", f"-chdir=tf/{project}", *extra_args],
                    cwd=repo_root,
                    capture=True,
                    check=False,
                )
                (run_dir / f"{project}.post-import.{plan_kind}.txt").write_text(
                    strip_ansi((completed.stdout or "") + (completed.stderr or ""))
                )
    finally:
        shutil.rmtree(temp_root, ignore_errors=True)

    if failures:
        raise RuntimeError("Import recovery had unresolved items:\n" + "\n".join(failures))


def main() -> None:
    args = parse_args()
    repo_root = Path(args.repo_root).resolve()
    run_id = args.run_id or f"tf-recover-cloudflare-state-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
    run_dir = repo_root / "docs/ai/runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=False)

    identity = Path(os.environ.get("AGE_KEY_FILE", str(Path.home() / ".ssh" / "id_ed25519")))
    manifest: list[dict[str, Any]]
    projects: list[str]

    if args.apply_from_run_id:
        manifest = load_prior_manifest(repo_root, args.apply_from_run_id)
        projects = unique([str(item["project"]) for item in manifest if item.get("project")])
        (run_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        write_command_file(repo_root, manifest, run_dir / "import-commands.sh")
        summary = {
            "run_id": run_id,
            "projects": projects,
            "entries_total": len(manifest),
            "resolved": sum(1 for item in manifest if item["status"] == "resolved"),
            "manual": sum(1 for item in manifest if item["status"] == "manual"),
            "missing": sum(1 for item in manifest if item["status"] == "missing"),
            "unsupported": sum(1 for item in manifest if item["status"] == "unsupported"),
            "run_dir": str(run_dir.relative_to(repo_root)),
            "apply_from_run_id": args.apply_from_run_id,
        }
        (run_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2))
        try:
            import_manifest(repo_root, manifest, run_dir, identity)
        finally:
            (run_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        return

    projects = args.projects or DEFAULT_PROJECTS
    token = resolve_cloudflare_api_token(repo_root, identity)
    account_id = resolve_cloudflare_account_id(repo_root, identity)

    (repo_root / "tmp").mkdir(exist_ok=True)
    workspace_root = Path(tempfile.mkdtemp(prefix=f"{run_id}-", dir=str(repo_root / "tmp")))
    try:
        copy_repo_to_workspace(repo_root, workspace_root)

        entries: list[dict[str, Any]] = []
        for project in projects:
            entries.extend(build_project_entries(workspace_root, project, run_dir))

        api = CloudflareAPI(token)
        ctx = ResolverContext(account_id=account_id, api=api, entries=entries)
        manifest = build_manifest(entries, ctx)
        (run_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        write_command_file(repo_root, manifest, run_dir / "import-commands.sh")

        summary = {
            "run_id": run_id,
            "projects": projects,
            "entries_total": len(manifest),
            "resolved": sum(1 for item in manifest if item["status"] == "resolved"),
            "manual": sum(1 for item in manifest if item["status"] == "manual"),
            "missing": sum(1 for item in manifest if item["status"] == "missing"),
            "unsupported": sum(1 for item in manifest if item["status"] == "unsupported"),
            "run_dir": str(run_dir.relative_to(repo_root)),
        }
        (run_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary, indent=2))

        if args.apply:
            try:
                import_manifest(repo_root, manifest, run_dir, identity)
            finally:
                (run_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    finally:
        if args.keep_workspace:
            print(f"kept workspace: {workspace_root}", file=sys.stderr)
        else:
            shutil.rmtree(workspace_root, ignore_errors=True)


if __name__ == "__main__":
    main()
