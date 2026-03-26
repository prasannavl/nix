#!/usr/bin/env python3
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import sys
import tempfile
import time
from collections import defaultdict
from pathlib import Path
from typing import Any


DEFAULT_PROJECTS = ["cloudflare-dns", "cloudflare-platform", "cloudflare-apps"]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--run-id")
    parser.add_argument("--from-run-id")
    parser.add_argument("--keep-workspace", action="store_true")
    parser.add_argument("--project", action="append", dest="projects")
    parser.add_argument("--zone", action="append", dest="zones")
    parser.add_argument("--worker", action="append", dest="workers")
    parser.add_argument("--tunnel", action="append", dest="tunnels")
    parser.add_argument("--r2-bucket", action="append", dest="r2_buckets")
    parser.add_argument("--address-contains", action="append", dest="address_contains")
    args = parser.parse_args()
    if not (args.zones or args.workers or args.tunnels or args.r2_buckets or args.address_contains):
        parser.error(
            "At least one selector is required: --zone, --worker, --tunnel, --r2-bucket, "
            "or --address-contains."
        )
    return args


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


def load_recovery_module(repo_root: Path) -> Any:
    path = repo_root / "scripts/archive/tf-recover-cloudflare-state.py"
    spec = importlib.util.spec_from_file_location("tf_recover_cloudflare_state", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load recovery helper: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def read_json(path: Path) -> Any:
    return json.loads(path.read_text())


def load_prior_run_bundle(repo_root: Path, run_id: str, projects: list[str]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    run_dir = repo_root / "docs/ai/runs" / run_id
    manifest_path = run_dir / "manifest.json"
    if not manifest_path.exists():
        raise FileNotFoundError(f"Manifest not found for prior run: {manifest_path}")

    manifest = read_json(manifest_path)
    entries: list[dict[str, Any]] = []
    for project in projects:
        desired_path = run_dir / f"{project}.desired.json"
        if not desired_path.exists():
            raise FileNotFoundError(f"Desired inventory not found for prior run: {desired_path}")
        entries.extend(read_json(desired_path))
    return entries, manifest


def build_fresh_bundle(
    repo_root: Path,
    recovery: Any,
    projects: list[str],
    run_dir: Path,
    keep_workspace: bool,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    identity = Path(os.environ.get("AGE_KEY_FILE", str(Path.home() / ".ssh" / "id_ed25519")))
    token = recovery.resolve_cloudflare_api_token(repo_root, identity)
    account_id = recovery.resolve_cloudflare_account_id(repo_root, identity)

    (repo_root / "tmp").mkdir(exist_ok=True)
    workspace_root = Path(tempfile.mkdtemp(prefix="tf-plan-cloudflare-state-migration-", dir=str(repo_root / "tmp")))
    try:
        recovery.copy_repo_to_workspace(repo_root, workspace_root)
        entries: list[dict[str, Any]] = []
        for project in projects:
            entries.extend(recovery.build_project_entries(workspace_root, project, run_dir))

        api = recovery.CloudflareAPI(token)
        ctx = recovery.ResolverContext(account_id=account_id, api=api, entries=entries)
        manifest = recovery.build_manifest(entries, ctx)
        return entries, manifest
    finally:
        if keep_workspace:
            print(f"kept workspace: {workspace_root}", file=sys.stderr)
        else:
            shutil.rmtree(workspace_root, ignore_errors=True)


def merge_entries(entries: list[dict[str, Any]], manifest: list[dict[str, Any]]) -> list[dict[str, Any]]:
    manifest_by_address = {item["address"]: item for item in manifest}
    merged: list[dict[str, Any]] = []
    for entry in entries:
        item = dict(entry)
        resolved = manifest_by_address.get(entry["address"], {})
        item["status"] = resolved.get("status", "unsupported")
        item["note"] = resolved.get("note", "")
        item["import_candidates"] = list(resolved.get("import_candidates", []))
        merged.append(item)
    return merged


def iter_strings(value: Any) -> list[str]:
    result: list[str] = []
    if isinstance(value, str):
        result.append(value)
    elif isinstance(value, dict):
        for nested in value.values():
            result.extend(iter_strings(nested))
    elif isinstance(value, list):
        for nested in value:
            result.extend(iter_strings(nested))
    return result


def value_contains_zone(value: str, zone: str) -> bool:
    lowered = value.lower()
    zone_lower = zone.lower()
    return zone_lower in lowered


def entry_worker_key(entry: dict[str, Any]) -> str | None:
    if entry.get("project") != "cloudflare-apps":
        return None
    after = entry.get("after") or {}
    for key in ("service", "script", "script_name", "name"):
        value = after.get(key)
        if isinstance(value, str) and value:
            return value
    index = str(entry.get("index") or "")
    if not index:
        return None
    return index.split("/", 1)[0]


def entry_bucket_key(entry: dict[str, Any]) -> str | None:
    entry_type = str(entry.get("type") or "")
    if not entry_type.startswith("cloudflare_r2_"):
        return None
    after = entry.get("after") or {}
    for key in ("bucket_name", "name"):
        value = after.get(key)
        if isinstance(value, str) and value:
            return value
    index = str(entry.get("index") or "")
    return index.split("/", 1)[0] if index else None


def entry_tunnel_key(entry: dict[str, Any]) -> str | None:
    entry_type = str(entry.get("type") or "")
    if not entry_type.startswith("cloudflare_zero_trust_tunnel_cloudflared"):
        return None
    index = str(entry.get("index") or "")
    return index.split("/", 1)[0] if index else None


def entry_zone_name(entry: dict[str, Any]) -> str | None:
    after = entry.get("after") or {}
    value = after.get("zone_name")
    return value if isinstance(value, str) and value else None


def collect_entry_strings(entry: dict[str, Any]) -> list[str]:
    strings = [
        str(entry.get("address") or ""),
        str(entry.get("index") or ""),
        str(entry.get("type") or ""),
    ]
    strings.extend(iter_strings(entry.get("after") or {}))
    return [value for value in strings if value]


def direct_selection_reasons(
    entry: dict[str, Any],
    zones: set[str],
    workers: set[str],
    tunnels: set[str],
    buckets: set[str],
    address_contains: list[str],
) -> set[str]:
    reasons: set[str] = set()
    strings = collect_entry_strings(entry)
    worker_key = entry_worker_key(entry)
    tunnel_key = entry_tunnel_key(entry)
    bucket_key = entry_bucket_key(entry)

    for zone in zones:
        if any(value_contains_zone(value, zone) for value in strings):
            reasons.add(f"zone:{zone}")

    if worker_key and worker_key in workers:
        reasons.add(f"worker:{worker_key}")
    if tunnel_key and tunnel_key in tunnels:
        reasons.add(f"tunnel:{tunnel_key}")
    if bucket_key and bucket_key in buckets:
        reasons.add(f"r2-bucket:{bucket_key}")

    for needle in address_contains:
        lowered = needle.lower()
        if any(lowered in value.lower() for value in strings):
            reasons.add(f"address-contains:{needle}")

    return reasons


def transitive_selection_reasons(
    entry: dict[str, Any],
    zones: set[str],
    workers: set[str],
    buckets: set[str],
    tunnels: set[str],
) -> set[str]:
    reasons: set[str] = set()

    zone_name = entry_zone_name(entry)
    if zone_name and zone_name in zones:
        reasons.add(f"zone:{zone_name}")

    worker_key = entry_worker_key(entry)
    if worker_key and worker_key in workers:
        reasons.add(f"worker:{worker_key}")

    bucket_key = entry_bucket_key(entry)
    if bucket_key and bucket_key in buckets:
        reasons.add(f"bucket:{bucket_key}")

    tunnel_key = entry_tunnel_key(entry)
    if tunnel_key and tunnel_key in tunnels:
        reasons.add(f"tunnel:{tunnel_key}")

    return reasons


def select_entries(
    entries: list[dict[str, Any]],
    zones: list[str],
    workers: list[str],
    tunnels: list[str],
    r2_buckets: list[str],
    address_contains: list[str],
) -> list[dict[str, Any]]:
    zone_set = {value.lower() for value in zones}
    worker_set = set(workers)
    tunnel_set = set(tunnels)
    bucket_set = set(r2_buckets)
    selected: dict[str, dict[str, Any]] = {}
    reasons_by_address: dict[str, set[str]] = defaultdict(set)

    for entry in entries:
        reasons = direct_selection_reasons(
            entry,
            zone_set,
            worker_set,
            tunnel_set,
            bucket_set,
            address_contains,
        )
        if reasons:
            selected[entry["address"]] = entry
            reasons_by_address[entry["address"]].update(reasons)

    changed = True
    while changed:
        changed = False
        expanded_bucket_set = set(bucket_set)
        expanded_bucket_set.update({
            bucket
            for entry in selected.values()
            for bucket in [entry_bucket_key(entry)]
            if bucket
        })
        expanded_tunnel_set = set(tunnel_set)
        expanded_tunnel_set.update({
            tunnel
            for entry in selected.values()
            for tunnel in [entry_tunnel_key(entry)]
            if tunnel
        })
        expanded_zone_set = set(zone_set)
        expanded_zone_set.update(
            zone.lower()
            for entry in selected.values()
            for zone in [entry_zone_name(entry)]
            if zone
        )
        expanded_worker_set = set(worker_set)
        expanded_worker_set.update(
            worker
            for entry in selected.values()
            for worker in [entry_worker_key(entry)]
            if worker
        )

        for entry in entries:
            if entry["address"] in selected:
                continue
            reasons = transitive_selection_reasons(
                entry,
                expanded_zone_set,
                expanded_worker_set,
                expanded_bucket_set,
                expanded_tunnel_set,
            )
            if not reasons:
                continue
            selected[entry["address"]] = entry
            reasons_by_address[entry["address"]].update(reasons)
            changed = True

    result: list[dict[str, Any]] = []
    for entry in entries:
        if entry["address"] not in selected:
            continue
        item = dict(entry)
        item["selection_reasons"] = sorted(reasons_by_address[entry["address"]])
        result.append(item)
    return result


def init_project(repo_root: Path, project: str) -> None:
    recovery = load_recovery_module(repo_root)
    recovery.run(
        ["./scripts/nixbot.sh", "tofu", f"-chdir=tf/{project}", "init", "-lockfile=readonly"],
        cwd=repo_root,
    )


def current_state_addresses(repo_root: Path, recovery: Any, project: str, run_dir: Path) -> set[str]:
    init_project(repo_root, project)
    recovery.snapshot_state(repo_root, project, run_dir)
    return recovery.existing_state_addresses(repo_root, project)


def write_import_header(lines: list[str], repo_root: Path) -> None:
    lines.extend(
        [
            "#!/usr/bin/env bash",
            "set -Eeuo pipefail",
            "",
            f"cd {quote_shell(str(repo_root))}",
            "",
            "# Run this against the target backend credentials/environment.",
            "# It imports the selected addresses and skips anything already present in that backend.",
            "",
            "mkdir -p tmp",
            'TF_MIGRATE_VAR_TMP="$(mktemp -d "tmp/tf-migrate-cloudflare-state.XXXXXX")"',
            'cleanup() { rm -rf "${TF_MIGRATE_VAR_TMP}"; }',
            "trap cleanup EXIT",
            "",
            'tf_migrate_provider_for_project() { printf \'%s\\n\' "${1%%-*}"; }',
            "",
            'tf_migrate_emit_var_paths() {',
            '  local project="$1" provider=""',
            '  provider="$(tf_migrate_provider_for_project "${project}")"',
            '  [ -f "data/secrets/tf/${provider}.tfvars.age" ] && printf \'%s\\n\' "data/secrets/tf/${provider}.tfvars.age"',
            '  [ -d "data/secrets/tf/${provider}" ] && find "data/secrets/tf/${provider}" -type f -name \'*.tfvars.age\' | sort',
            '  [ -f "data/secrets/tf/${project}.tfvars.age" ] && printf \'%s\\n\' "data/secrets/tf/${project}.tfvars.age"',
            '  [ -d "data/secrets/tf/${project}" ] && find "data/secrets/tf/${project}" -type f -name \'*.tfvars.age\' | sort',
            "}",
            "",
            'tf_migrate_state_has() {',
            '  local project="$1" address="$2"',
            '  ./scripts/nixbot.sh tofu "-chdir=tf/${project}" state list 2>/dev/null | grep -Fx -- "${address}" >/dev/null',
            "}",
            "",
            'tf_migrate_import() {',
            '  local project="$1" address="$2" import_id="$3" identity="" source="" out="" index=0',
            '  local -a cmd=(./scripts/nixbot.sh tofu "-chdir=tf/${project}" import)',
            '  if tf_migrate_state_has "${project}" "${address}"; then',
            '    printf \'skip existing: %s\\n\' "${address}" >&2',
            "    return 0",
            "  fi",
            '  identity="${AGE_KEY_FILE:-${HOME}/.ssh/id_ed25519}"',
            '  while IFS= read -r source; do',
            '    [ -n "${source}" ] || continue',
            '    out="${TF_MIGRATE_VAR_TMP}/${project}-${index}.tfvars"',
            '    age --decrypt -i "${identity}" -o "${out}" "${source}"',
            '    chmod 600 "${out}"',
            '    cmd+=("-var-file=${out}")',
            '    index=$((index + 1))',
            '  done < <(tf_migrate_emit_var_paths "${project}")',
            '  cmd+=("${address}" "${import_id}")',
            '  "${cmd[@]}"',
            "}",
            "",
        ]
    )


def write_remove_header(lines: list[str], repo_root: Path) -> None:
    lines.extend(
        [
            "#!/usr/bin/env bash",
            "set -Eeuo pipefail",
            "",
            f"cd {quote_shell(str(repo_root))}",
            "",
            "# Run this only after the target import wave is verified.",
            "# It removes the selected addresses from the source backend and skips any missing state entries.",
            "",
            'tf_migrate_state_has() {',
            '  local project="$1" address="$2"',
            '  ./scripts/nixbot.sh tofu "-chdir=tf/${project}" state list 2>/dev/null | grep -Fx -- "${address}" >/dev/null',
            "}",
            "",
            'tf_migrate_state_rm() {',
            '  local project="$1" address="$2"',
            '  if ! tf_migrate_state_has "${project}" "${address}"; then',
            '    printf \'skip missing: %s\\n\' "${address}" >&2',
            "    return 0",
            "  fi",
            '  ./scripts/nixbot.sh tofu "-chdir=tf/${project}" state rm "${address}"',
            "}",
            "",
        ]
    )


def write_import_script(repo_root: Path, entries: list[dict[str, Any]], output_path: Path) -> None:
    lines: list[str] = []
    write_import_header(lines, repo_root)

    by_project: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for entry in entries:
        by_project[entry["project"]].append(entry)

    for project in unique([entry["project"] for entry in entries]):
        lines.append(f"# Project: {project}")
        lines.append(f"./scripts/nixbot.sh tofu -chdir=tf/{project} init -lockfile=readonly")
        lines.append("")
        for entry in by_project[project]:
            lines.append(
                f"# {entry['address']} [{entry['status']}]"
                + (f" reasons={','.join(entry['selection_reasons'])}" if entry.get("selection_reasons") else "")
            )
            if entry["status"] != "resolved":
                lines.append(f"# {entry.get('note') or 'unresolved'}")
                lines.append("")
                continue
            lines.append(
                " ".join(
                    [
                        "tf_migrate_import",
                        quote_shell(entry["project"]),
                        quote_shell(entry["address"]),
                        quote_shell(entry["import_candidates"][0]),
                    ]
                )
            )
            lines.append("")

    output_path.write_text("\n".join(lines) + "\n")
    output_path.chmod(0o755)


def write_remove_script(repo_root: Path, entries: list[dict[str, Any]], output_path: Path) -> None:
    lines: list[str] = []
    write_remove_header(lines, repo_root)

    by_project: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for entry in entries:
        by_project[entry["project"]].append(entry)

    for project in unique([entry["project"] for entry in entries]):
        lines.append(f"# Project: {project}")
        lines.append(f"./scripts/nixbot.sh tofu -chdir=tf/{project} init -lockfile=readonly")
        lines.append("")
        for entry in by_project[project]:
            lines.append(
                f"# {entry['address']} [{entry['status']}]"
                + (f" reasons={','.join(entry['selection_reasons'])}" if entry.get("selection_reasons") else "")
            )
            if entry["status"] != "resolved":
                lines.append(f"# {entry.get('note') or 'unresolved'}")
                lines.append("")
                continue
            if not entry.get("present_in_current_state"):
                lines.append("# Not present in the source state snapshot used for this plan.")
                lines.append("")
                continue
            lines.append(
                " ".join(
                    [
                        "tf_migrate_state_rm",
                        quote_shell(entry["project"]),
                        quote_shell(entry["address"]),
                    ]
                )
            )
            lines.append("")

    output_path.write_text("\n".join(lines) + "\n")
    output_path.chmod(0o755)


def summarize(entries: list[dict[str, Any]], run_id: str, run_dir: Path, source_run_id: str | None) -> dict[str, Any]:
    selected_projects = unique([entry["project"] for entry in entries])
    return {
        "run_id": run_id,
        "projects": selected_projects,
        "selected_total": len(entries),
        "resolved": sum(1 for entry in entries if entry["status"] == "resolved"),
        "manual": sum(1 for entry in entries if entry["status"] == "manual"),
        "missing": sum(1 for entry in entries if entry["status"] == "missing"),
        "unsupported": sum(1 for entry in entries if entry["status"] == "unsupported"),
        "source_present": sum(1 for entry in entries if entry.get("present_in_current_state")),
        "run_dir": str(run_dir),
        "from_run_id": source_run_id,
    }


def main() -> None:
    args = parse_args()
    repo_root = Path(args.repo_root).resolve()
    run_id = args.run_id or f"tf-plan-cloudflare-state-migration-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
    run_dir = repo_root / "docs/ai/runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=False)

    projects = args.projects or DEFAULT_PROJECTS
    recovery = load_recovery_module(repo_root)

    if args.from_run_id:
        entries, manifest = load_prior_run_bundle(repo_root, args.from_run_id, projects)
    else:
        entries, manifest = build_fresh_bundle(repo_root, recovery, projects, run_dir, args.keep_workspace)
        (run_dir / "manifest.full.json").write_text(json.dumps(manifest, indent=2) + "\n")

    merged_entries = merge_entries(entries, manifest)
    selected_entries = select_entries(
        merged_entries,
        zones=args.zones or [],
        workers=args.workers or [],
        tunnels=args.tunnels or [],
        r2_buckets=args.r2_buckets or [],
        address_contains=args.address_contains or [],
    )

    for project in unique([entry["project"] for entry in selected_entries]):
        present_addresses = current_state_addresses(repo_root, recovery, project, run_dir)
        for entry in selected_entries:
            if entry["project"] != project:
                continue
            entry["present_in_current_state"] = entry["address"] in present_addresses

    (run_dir / "selected-manifest.json").write_text(json.dumps(selected_entries, indent=2) + "\n")
    write_import_script(repo_root, selected_entries, run_dir / "import-into-target.sh")
    write_remove_script(repo_root, selected_entries, run_dir / "remove-from-source.sh")
    (run_dir / "selected-addresses.txt").write_text(
        "".join(f"{entry['address']}\n" for entry in selected_entries)
    )

    summary = summarize(selected_entries, run_id, run_dir.relative_to(repo_root), args.from_run_id)
    (run_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
