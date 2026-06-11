#!/usr/bin/env python3
import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path

import yaml

DEFAULT_NIXBOT_DIRTY_FLAG = "--dirty-staged"


def die(message):
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def info(message):
    print(message, file=sys.stderr)


def run(argv, *, cwd=None, dry_run=False):
    rendered = shlex.join([str(arg) for arg in argv])
    if cwd is not None:
        rendered = f"(cd {shlex.quote(str(cwd))} && {rendered})"
    if dry_run:
        info(f"dry-run: {rendered}")
        return
    result = subprocess.run([str(arg) for arg in argv], cwd=cwd)
    if result.returncode != 0:
        die(f"command failed with exit status {result.returncode}: {rendered}")


def run_capture(argv, *, dry_run=False, default=None):
    rendered = shlex.join([str(arg) for arg in argv])
    if dry_run:
        info(f"dry-run: {rendered}")
        return default
    result = subprocess.run(
        [str(arg) for arg in argv],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        if default is not None:
            return default
        if result.stderr:
            print(result.stderr, file=sys.stderr, end="")
        die(f"command failed with exit status {result.returncode}: {rendered}")
    return result.stdout


def command_succeeds(argv, *, dry_run=False):
    rendered = shlex.join([str(arg) for arg in argv])
    if dry_run:
        info(f"dry-run: {rendered}")
        return True
    result = subprocess.run(
        [str(arg) for arg in argv],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def run_shell(command, *, dry_run=False):
    if dry_run:
        info(f"dry-run: {command}")
        return
    result = subprocess.run(command, shell=True, executable="/bin/sh")
    if result.returncode != 0:
        die(f"command failed with exit status {result.returncode}: {command}")


def find_repo_root(start):
    path = Path(start).resolve()
    for candidate in [path, *path.parents]:
        if (candidate / "flake.nix").is_file() and (
            candidate / "pkgs/manifest.nix"
        ).is_file():
            return candidate
    die("could not find repo root; pass --repo-root")


def load_plan(repo_root, profile, config_path):
    path = Path(config_path) if config_path else default_config_path(repo_root, profile)
    if not path.is_file():
        die(f"data-migrator config not found: {path}")
    with path.open("r", encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}
    if not isinstance(data, dict):
        die(f"data-migrator config must be a YAML mapping: {path}")
    return path, data


def default_config_path(repo_root, profile):
    filename = f"{profile}.yaml"
    candidates = []
    env_config_dir = os.environ.get("DATA_MIGRATOR_CONFIG_DIR")
    if env_config_dir:
        candidates.append(Path(env_config_dir) / filename)
    candidates.extend(
        [
            repo_root / "pkgs/tools/data-migrator/config" / filename,
        ]
    )
    for path in candidates:
        if path.is_file():
            return path
    return candidates[0]


def normalize_path_entry(entry):
    if isinstance(entry, str):
        return {"path": entry, "excludes": []}
    if not isinstance(entry, dict):
        die(f"path entries must be strings or mappings: {entry!r}")
    path = entry.get("path")
    if not isinstance(path, str) or path == "":
        die(f"path entry is missing a non-empty path: {entry!r}")
    excludes = entry.get("excludes", [])
    if excludes is None:
        excludes = []
    if not isinstance(excludes, list) or not all(
        isinstance(item, str) for item in excludes
    ):
        die(f"path entry excludes must be a list of strings: {entry!r}")
    return {"path": path, "excludes": excludes}


def plan_paths(plan):
    paths = plan.get("paths", [])
    if not isinstance(paths, list):
        die("config paths must be a list")
    return [normalize_path_entry(entry) for entry in paths]


def plan_excludes(plan):
    excludes = plan.get("excludes", [])
    if excludes is None:
        return []
    if not isinstance(excludes, list) or not all(
        isinstance(item, str) for item in excludes
    ):
        die("config excludes must be a list of strings")
    return excludes


def plan_source_paths(plan):
    if "source_paths" not in plan:
        return plan_paths(plan), plan_excludes(plan)

    source_paths = plan.get("source_paths", [])
    if source_paths is None:
        source_paths = []
    if not isinstance(source_paths, list):
        die("config source_paths must be a list")

    paths = []
    excludes = []
    for item in source_paths:
        if not isinstance(item, str) or item == "":
            die(f"source_paths entries must be non-empty strings: {item!r}")
        if item.startswith("!"):
            pattern = item[1:]
            if pattern == "":
                die("source_paths exclude entries must include a pattern after '!'")
            excludes.append(pattern)
        else:
            paths.append({"path": item, "excludes": []})
    return paths, excludes


def validate_exclude(pattern):
    if pattern.startswith("./"):
        if pattern == "./":
            die("relative exclude './' is too broad")
        return
    if pattern.startswith("/"):
        if pattern == "/":
            die("absolute exclude '/' is too broad")
        return
    die(f"exclude must be an absolute path or start with './': {pattern}")


def normalize_absolute_path(path):
    normalized = os.path.normpath(path)
    return normalized if normalized.startswith("/") else f"/{normalized}"


def exclude_for_path(pattern, source_path):
    validate_exclude(pattern)
    if pattern.startswith("./"):
        return "/" + pattern[2:].lstrip("/")

    source_root = normalize_absolute_path(source_path)
    exclude_path = normalize_absolute_path(pattern)
    trailing = "/" if pattern.endswith("/") and exclude_path != "/" else ""
    if exclude_path == source_root:
        return "/***"
    prefix = source_root.rstrip("/") + "/"
    if not exclude_path.startswith(prefix):
        return None
    rel = exclude_path[len(source_root.rstrip("/")) :].rstrip("/")
    return rel + trailing


def excludes_for_path(raw_excludes, source_path):
    patterns = []
    for pattern in raw_excludes:
        resolved = exclude_for_path(pattern, source_path)
        if resolved is not None:
            patterns.append(resolved)
    return patterns


def plan_string(plan, name):
    value = plan.get(name)
    if value is None:
        return None
    if not isinstance(value, str) or value == "":
        die(f"config {name} must be a non-empty string when set")
    return value


def ensure_under_base(path, base):
    path_obj = Path(path)
    base_obj = Path(base)
    try:
        return path_obj.relative_to(base_obj)
    except ValueError:
        return Path(path_obj.name)


def trailing_slash(path):
    return path.rstrip("/") + "/"


def default_source_rsync_path():
    return "sudo -n nix shell nixpkgs#rsync -c rsync"


def plan_mapping(plan, name):
    value = plan.get(name, {})
    if value is None:
        return {}
    if not isinstance(value, dict):
        die(f"config {name} must be a mapping when set")
    return value


def resolve_transport(args):
    if args.transport != "auto":
        return args.transport
    if args.target_dir:
        if shutil.which("rsync"):
            return "rsync"
        return "tar"
    probe_host = args.target_host if args.copy_mode == "pull" else args.source_host
    if probe_host and command_succeeds(
        ["ssh", probe_host, "command -v rsync >/dev/null 2>&1"], dry_run=args.dry_run
    ):
        return "rsync"
    return "tar"


def rsync_common_args(excludes, *, ssh_command=None):
    args = [
        "rsync",
        "-aHAXS",
        "--numeric-ids",
        "--delete",
        "--one-file-system",
        "--human-readable",
        "--info=progress2",
        "--outbuf=N",
    ]
    if ssh_command:
        args.extend(["-e", ssh_command])
    for pattern in excludes:
        args.extend(["--exclude", pattern])
    return args


def append_rsync_endpoint_args(base_args, source, destination, *, rsync_path=None):
    args = list(base_args)
    if rsync_path:
        args.extend(["--rsync-path", rsync_path])
    args.extend([source, destination])
    return args


def sudo_prefix(enabled):
    return "sudo -n " if enabled else ""


def shell_quote(value):
    return shlex.quote(str(value))


def tar_excludes(excludes):
    result = []
    for pattern in excludes:
        if pattern == "/***":
            result.append("--exclude=./*")
            continue
        stripped = pattern.lstrip("/")
        if not stripped:
            continue
        result.append(f"--exclude={stripped.rstrip('/')}")
        result.append(f"--exclude=./{stripped.rstrip('/')}")
    return result


def safe_clean_command(path, *, sudo=False):
    normalized = os.path.normpath(str(path))
    if normalized in {"/", ".", ""}:
        die(f"refusing to clean unsafe destination path: {path}")
    return (
        f"{sudo_prefix(sudo)}install -d {shell_quote(normalized)} && "
        f"{sudo_prefix(sudo)}find {shell_quote(normalized)} "
        "-mindepth 1 -xdev -exec rm -rf -- {} +"
    )


def tar_create_command(path, excludes, *, sudo=False):
    tar_args = ["tar", "-C", path, *tar_excludes(excludes), "-cpf", "-", "."]
    return sudo_prefix(sudo) + quote_remote_command(tar_args)


def tar_extract_command(path, *, sudo=False):
    tar_args = ["tar", "-C", path, "-xpf", "-"]
    return sudo_prefix(sudo) + quote_remote_command(tar_args)


def migrate_one_path_with_tar(args, entry, phase, destination, excludes):
    source_path = entry["path"]
    dest_path = trailing_slash(destination)
    info(
        f"{phase}: {source_path} -> {args.target_host or args.target_dir}:{destination} (tar)"
    )

    if args.target_dir:
        # The caller passes the already mapped destination for remote copies. For
        # local staging, preserve the same relative layout under --target-dir.
        local_dest = trailing_slash(
            str(Path(args.target_dir) / args.current_relative_path)
        )
        clean = safe_clean_command(local_dest, sudo=args.local_sudo)
        create = (
            "ssh "
            f"{shell_quote(args.source_host)} "
            f"{shell_quote(tar_create_command(source_path, excludes, sudo=args.remote_sudo))}"
        )
        run_shell(
            f"{clean} && {create} | {tar_extract_command(local_dest, sudo=args.local_sudo)}",
            dry_run=args.dry_run,
        )
        return

    if args.copy_mode == "pull":
        clean = safe_clean_command(dest_path, sudo=args.remote_sudo)
        create = (
            "ssh "
            f"{shell_quote(args.source_host)} "
            f"{shell_quote(tar_create_command(source_path, excludes, sudo=args.remote_sudo))}"
        )
        extract = tar_extract_command(dest_path, sudo=args.remote_sudo)
        remote_shell(
            args.target_host, f"{clean} && {create} | {extract}", dry_run=args.dry_run
        )
        return

    if args.copy_mode == "push":
        clean = safe_clean_command(dest_path, sudo=args.remote_sudo)
        extract = tar_extract_command(dest_path, sudo=args.remote_sudo)
        target_extract = (
            "ssh "
            f"{shell_quote(args.target_host)} "
            f"{shell_quote(f'{clean} && {extract}')}"
        )
        create = tar_create_command(source_path, excludes, sudo=args.remote_sudo)
        remote_shell(
            args.source_host, f"{create} | {target_extract}", dry_run=args.dry_run
        )
        return

    die(f"unsupported copy mode: {args.copy_mode}")


def quote_remote_command(argv):
    return shlex.join([str(arg) for arg in argv])


def remote_shell(host, command, *, dry_run=False):
    run(["ssh", host, command], dry_run=dry_run)


def via_incus_controller(args, argv):
    if not args.incus_controller_host:
        return list(argv)
    return ["ssh", args.incus_controller_host, quote_remote_command(argv)]


def run_incus(args, argv):
    run(via_incus_controller(args, argv), dry_run=args.dry_run)


def capture_incus(args, argv, *, default=None):
    return run_capture(
        via_incus_controller(args, argv), dry_run=args.dry_run, default=default
    )


def incus_command_succeeds(args, argv):
    return command_succeeds(via_incus_controller(args, argv), dry_run=args.dry_run)


def incus_ref(remote, name):
    if remote in {None, "", "local"}:
        return name
    return f"{remote}:{name}"


def incus_query_ref(remote, path, project=None):
    query = path
    if project:
        separator = "&" if "?" in query else "?"
        query = f"{query}{separator}project={urllib.parse.quote(project)}"
    if remote in {None, "", "local"}:
        return query
    return f"{remote}:{query}"


def incus_args(project, *argv):
    args = ["incus"]
    if project:
        args.extend(["--project", project])
    args.extend(argv)
    return args


def incus_json(args, remote, path, project=None, *, default=None):
    output = capture_incus(
        args,
        ["incus", "query", incus_query_ref(remote, path, project), "--raw"],
        default=None if default is None else json.dumps(default),
    )
    if output is None:
        return default
    try:
        return json.loads(output)
    except json.JSONDecodeError as exc:
        die(f"Incus returned invalid JSON for {path}: {exc}")


def incus_instance(args, remote, project, name, *, missing_ok=False):
    if args.dry_run and not missing_ok:
        return {
            "metadata": {
                "status": "Running",
                "expanded_devices": {
                    "root": {
                        "type": "disk",
                        "path": "/",
                        "pool": "default",
                    }
                },
            }
        }
    encoded = urllib.parse.quote(name, safe="")
    query = incus_query_ref(remote, f"/1.0/instances/{encoded}", project)
    if missing_ok:
        output = capture_incus(
            args,
            ["incus", "query", query, "--raw"],
            default="",
        )
        if not output:
            return None
        try:
            return json.loads(output)
        except json.JSONDecodeError as exc:
            die(f"Incus returned invalid JSON for {name}: {exc}")
    default = None if missing_ok else None
    try:
        return incus_json(
            args,
            remote,
            f"/1.0/instances/{encoded}",
            project,
            default=default,
        )
    except SystemExit:
        if missing_ok:
            return None
        raise


def instance_status(instance_json):
    metadata = instance_json.get("metadata", instance_json)
    return metadata.get("status", "")


def root_disk_pool(instance_json):
    metadata = instance_json.get("metadata", instance_json)
    devices = metadata.get("expanded_devices") or metadata.get("devices") or {}
    for config in devices.values():
        if config.get("type") == "disk" and config.get("path") == "/":
            return config.get("pool")
    return None


def instance_config(instance_json):
    metadata = instance_json.get("metadata", instance_json)
    return metadata.get("config") or {}


def storage_pool_driver(args, remote, pool):
    if not pool:
        return None
    encoded = urllib.parse.quote(pool, safe="")
    pool_json = incus_json(args, remote, f"/1.0/storage-pools/{encoded}", default={})
    metadata = pool_json.get("metadata", pool_json)
    return metadata.get("driver")


def migration_marker(args):
    return {
        "user.data-migrator.source-instance": args.incus_instance,
        "user.data-migrator.source-project": args.source_project or "",
        "user.data-migrator.source-remote": args.incus_remote or "local",
    }


def ensure_refresh_target_matches(args, target_instance_json):
    config = instance_config(target_instance_json)
    expected = migration_marker(args)
    actual = {key: config.get(key) for key in expected}

    if actual == expected:
        return
    if args.force_refresh_existing:
        info(
            "incus: force-refresh-existing set; refreshing target without matching "
            "data-migrator source marker"
        )
        return

    missing = [key for key, value in actual.items() if value is None]
    if missing:
        die(
            f"target instance {args.target_instance} already exists without a "
            "data-migrator source marker; pass --force-refresh-existing to "
            "refresh it anyway"
        )

    details = ", ".join(
        f"{key}={actual[key]!r} expected {expected[key]!r}" for key in expected
    )
    die(
        f"target instance {args.target_instance} was created from a different "
        f"source ({details}); pass --force-refresh-existing to refresh it anyway"
    )


def mark_refresh_target(args):
    command = incus_args(
        args.target_project,
        "config",
        "set",
        incus_ref(args.target_incus_remote, args.target_instance),
    )
    command.extend(f"{key}={value}" for key, value in migration_marker(args).items())
    run_incus(args, command)


def incus_snapshot_name(args, phase):
    timestamp = time.strftime("%Y%m%d%H%M%S")
    return f"{args.snapshot_prefix}-{phase}-{timestamp}"


def incus_snapshot_create(
    args, project, remote, instance, snapshot_name, *, stateful=False
):
    command = incus_args(
        project,
        "snapshot",
        "create",
        incus_ref(remote, instance),
        snapshot_name,
        "--reuse",
        "--no-expiry",
    )
    if stateful:
        command.append("--stateful")
    run_incus(args, command)


def incus_snapshot_delete(args, project, remote, instance, snapshot_name):
    command = incus_args(
        project,
        "snapshot",
        "delete",
        incus_ref(remote, instance),
        snapshot_name,
    )
    if not incus_command_succeeds(args, command):
        info(
            f"incus: snapshot already absent or could not be deleted: {project}/{instance}/{snapshot_name}"
        )


def incus_stop_instance(args, project, remote, instance, status):
    if status != "Running":
        return False
    command = incus_args(
        project,
        "stop",
        incus_ref(remote, instance),
        "--timeout",
        str(args.incus_stop_timeout),
    )
    run_incus(args, command)
    return True


def incus_start_instance(args, project, remote, instance):
    run_incus(args, incus_args(project, "start", incus_ref(remote, instance)))


def incus_copy_instance(args, *, refresh=False):
    command = incus_args(
        args.source_project,
        "copy",
        incus_ref(args.incus_remote, args.incus_instance),
        incus_ref(args.target_incus_remote, args.target_instance),
        "--storage",
        args.target_storage_pool,
        "--mode",
        args.incus_copy_mode,
    )
    if args.target_project and args.target_project != args.source_project:
        command.extend(["--target-project", args.target_project])
    if refresh:
        command.extend(["--refresh", "--refresh-exclude-older"])
    if args.incus_stateless:
        command.append("--stateless")
    if args.incus_allow_inconsistent:
        command.append("--allow-inconsistent")
    run_incus(args, command)


def incus_copy_or_refresh_instance(args, *, target_exists):
    if target_exists:
        incus_copy_instance(args, refresh=True)
    else:
        incus_copy_instance(args)
    mark_refresh_target(args)


def is_fast_incus_path(args, source_instance_json):
    if args.incus_migration_mode == "files":
        return False
    if args.incus_remote != args.target_incus_remote:
        return False

    source_pool = root_disk_pool(source_instance_json)
    args.target_storage_pool = args.target_storage_pool or source_pool
    if not source_pool or args.target_storage_pool != source_pool:
        return False

    source_driver = storage_pool_driver(args, args.incus_remote, source_pool)
    return source_driver == "btrfs"


def migrate_incus_instance(args, plan):
    incus_config = plan_mapping(plan, "incus")
    args.incus_instance = (
        args.incus_instance or incus_config.get("instance") or args.profile
    )
    args.target_instance = (
        args.target_instance
        or incus_config.get("target_instance")
        or args.incus_instance
    )
    args.source_project = args.source_project or incus_config.get("source_project")
    args.target_project = (
        args.target_project or incus_config.get("target_project") or args.source_project
    )
    args.incus_controller_host = (
        args.incus_controller_host
        or incus_config.get("controller_host")
        or incus_config.get("controller")
    )
    args.incus_remote = args.incus_remote or incus_config.get("remote") or "local"
    args.target_incus_remote = (
        args.target_incus_remote
        or incus_config.get("target_remote")
        or args.incus_remote
    )
    args.target_storage_pool = args.target_storage_pool or incus_config.get(
        "target_storage_pool"
    )

    source_instance_json = incus_instance(
        args,
        args.incus_remote,
        args.source_project,
        args.incus_instance,
    )
    source_was_running = instance_status(source_instance_json) == "Running"
    source_pool = root_disk_pool(source_instance_json)
    args.target_storage_pool = args.target_storage_pool or source_pool
    if not args.target_storage_pool:
        die(f"could not determine target storage pool for {args.incus_instance}")
    target_instance_json = incus_instance(
        args,
        args.target_incus_remote,
        args.target_project,
        args.target_instance,
        missing_ok=True,
    )
    target_was_running = (
        instance_status(target_instance_json) == "Running"
        if target_instance_json
        else False
    )
    if target_instance_json:
        ensure_refresh_target_matches(args, target_instance_json)

    fast_path = is_fast_incus_path(args, source_instance_json)
    native_path = fast_path or args.incus_migration_mode == "incus-native"
    if fast_path:
        source_label = f"{args.source_project or 'default'}/{args.incus_instance}"
        target_label = f"{args.target_project or 'default'}/{args.target_instance}"
        info(
            "incus: using native btrfs snapshot/refresh path "
            f"for {source_label} -> {target_label}"
        )
    else:
        if args.incus_migration_mode == "incus-native":
            info("incus: using requested native Incus copy path")
        else:
            info("incus: btrfs fast path unavailable; using file-copy fallback")

    target_drain_host = (
        args.target_drain_host
        or plan_string(plan, "target_drain_host")
        or args.target_host
        or args.target_instance
    )
    source_drain_host = (
        args.source_drain_host
        or plan_string(plan, "source_drain_host")
        or args.incus_instance
    )
    drained_hosts = set()

    def drain_host(host):
        if host and host not in drained_hosts:
            deploy_drain(args, host, True)
            drained_hosts.add(host)

    def resume_host(host):
        if host and host in drained_hosts:
            deploy_drain(args, host, False)
            drained_hosts.remove(host)

    def resume_target_host(host):
        if host and host in drained_hosts:
            deploy_target_resumed(args, host)
            drained_hosts.remove(host)

    if native_path:
        seed_snapshot = incus_snapshot_name(args, "seed")
        final_snapshot = incus_snapshot_name(args, "final")
        created_snapshots = []
        try:
            incus_snapshot_create(
                args,
                args.source_project,
                args.incus_remote,
                args.incus_instance,
                seed_snapshot,
            )
            created_snapshots.append(seed_snapshot)
            incus_copy_or_refresh_instance(
                args, target_exists=target_instance_json is not None
            )
            target_instance_json = incus_instance(
                args,
                args.target_incus_remote,
                args.target_project,
                args.target_instance,
                missing_ok=False,
            )
            if not args.warm:
                if target_drain_host:
                    if instance_status(target_instance_json) != "Running":
                        incus_start_instance(
                            args,
                            args.target_project,
                            args.target_incus_remote,
                            args.target_instance,
                        )
                        target_instance_json = incus_instance(
                            args,
                            args.target_incus_remote,
                            args.target_project,
                            args.target_instance,
                            missing_ok=False,
                        )
                    deploy_target_prepared(args, target_drain_host)
                    drain_host(target_drain_host)
                if not args.skip_source_drain and source_drain_host:
                    drain_host(source_drain_host)
                incus_stop_instance(
                    args,
                    args.source_project,
                    args.incus_remote,
                    args.incus_instance,
                    "Running"
                    if source_was_running
                    else instance_status(source_instance_json),
                )
                target_instance_json = incus_instance(
                    args,
                    args.target_incus_remote,
                    args.target_project,
                    args.target_instance,
                    missing_ok=False,
                )
                incus_stop_instance(
                    args,
                    args.target_project,
                    args.target_incus_remote,
                    args.target_instance,
                    instance_status(target_instance_json),
                )
                incus_snapshot_create(
                    args,
                    args.source_project,
                    args.incus_remote,
                    args.incus_instance,
                    final_snapshot,
                )
                created_snapshots.append(final_snapshot)
                incus_copy_or_refresh_instance(args, target_exists=True)
                if (source_was_running or target_was_running) and not args.no_start_target:
                    incus_start_instance(
                        args,
                        args.target_project,
                        args.target_incus_remote,
                        args.target_instance,
                    )
                if args.leave_source_running and source_was_running:
                    incus_start_instance(
                        args, args.source_project, args.incus_remote, args.incus_instance
                    )
        finally:
            for snapshot in created_snapshots:
                incus_snapshot_delete(
                    args,
                    args.source_project,
                    args.incus_remote,
                    args.incus_instance,
                    snapshot,
                )
                incus_snapshot_delete(
                    args,
                    args.target_project,
                    args.target_incus_remote,
                    args.target_instance,
                    snapshot,
                )
    else:
        if not args.target_host and not args.target_dir:
            die("file-copy fallback needs --target-host or --target-dir")
        args.effective_transport = resolve_transport(args)
        if target_drain_host and not args.warm:
            deploy_target_prepared(args, target_drain_host)
            drain_host(target_drain_host)
        migrate_paths(args, plan, "warm" if args.warm else "seed")
        if not args.warm:
            if not args.skip_source_drain and source_drain_host:
                drain_host(source_drain_host)
            incus_stop_instance(
                args,
                args.source_project,
                args.incus_remote,
                args.incus_instance,
                "Running"
                if source_was_running
                else instance_status(source_instance_json),
            )
            if target_instance_json:
                incus_stop_instance(
                    args,
                    args.target_project,
                    args.target_incus_remote,
                    args.target_instance,
                    "Running"
                    if target_was_running
                    else instance_status(target_instance_json),
                )
            migrate_paths(args, plan, "final")
            if (source_was_running or target_was_running) and not args.no_start_target:
                incus_start_instance(
                    args,
                    args.target_project,
                    args.target_incus_remote,
                    args.target_instance,
                )
            if args.leave_source_running and source_was_running:
                incus_start_instance(
                    args, args.source_project, args.incus_remote, args.incus_instance
                )

    if target_drain_host and not args.no_resume_target and not args.warm:
        resume_target_host(target_drain_host)
    if (
        args.resume_source
        and not args.skip_source_drain
        and source_drain_host
        and not args.warm
    ):
        resume_host(source_drain_host)


def migrate_one_path(args, plan, entry, phase, raw_excludes):
    configured_source_path_base = (
        plan.get("source_path_base")
        or plan.get("source_base")
        or plan.get("base")
        or plan.get("target_path_base")
        or plan.get("target_base")
        or "/var/lib/abird"
    )
    target_path_base = (
        args.target_base
        or plan.get("target_path_base")
        or plan.get("target_base")
        or plan.get("base")
        or "/var/lib/abird"
    )
    source_path_base = args.source_base or configured_source_path_base
    rel = ensure_under_base(entry["path"], source_path_base)
    destination = str(Path(target_path_base) / rel)
    excludes = excludes_for_path(raw_excludes + entry["excludes"], entry["path"])
    if args.effective_transport == "tar":
        args.current_relative_path = rel
        migrate_one_path_with_tar(args, entry, phase, destination, excludes)
        return

    common = rsync_common_args(excludes, ssh_command=args.rsync_ssh)
    source_path = trailing_slash(entry["path"])
    dest_path = trailing_slash(destination)
    source_spec = f"{args.source_host}:{source_path}"

    info(
        f"{phase}: {entry['path']} -> {args.target_host or args.target_dir}:{destination} (rsync)"
    )

    if args.target_dir:
        local_dest = trailing_slash(str(Path(args.target_dir) / rel))
        mkdir = ["install", "-d", local_dest]
        if args.local_sudo:
            mkdir.insert(0, "sudo")
        run(mkdir, dry_run=args.dry_run)
        rsync = append_rsync_endpoint_args(
            common,
            source_spec,
            local_dest,
            rsync_path=args.source_rsync_path,
        )
        run(rsync, dry_run=args.dry_run)
        return

    if args.copy_mode == "pull":
        mkdir = ["install", "-d", dest_path]
        if args.remote_sudo:
            mkdir.insert(0, "sudo")
        remote_shell(
            args.target_host, quote_remote_command(mkdir), dry_run=args.dry_run
        )
        rsync = append_rsync_endpoint_args(
            common,
            source_spec,
            dest_path,
            rsync_path=args.source_rsync_path,
        )
        if args.remote_sudo:
            rsync.insert(0, "sudo")
        remote_shell(
            args.target_host, quote_remote_command(rsync), dry_run=args.dry_run
        )
        return

    if args.copy_mode == "push":
        mkdir = ["install", "-d", dest_path]
        if args.remote_sudo:
            mkdir.insert(0, "sudo")
        remote_shell(
            args.target_host, quote_remote_command(mkdir), dry_run=args.dry_run
        )
        target_spec = f"{args.target_host}:{dest_path}"
        rsync = append_rsync_endpoint_args(
            common,
            source_path,
            target_spec,
            rsync_path="sudo rsync" if args.remote_sudo else None,
        )
        remote_shell(
            args.source_host, quote_remote_command(rsync), dry_run=args.dry_run
        )
        return

    die(f"unsupported copy mode: {args.copy_mode}")


def migrate_paths(args, plan, phase):
    paths, raw_excludes = plan_source_paths(plan)
    for entry in paths:
        migrate_one_path(args, plan, entry, phase, raw_excludes)


def render_nix_value(value, indent=0):
    if isinstance(value, dict):
        if not value:
            return "{}"
        current_indent = "  " * indent
        child_indent = "  " * (indent + 1)
        lines = ["{"]
        for key in sorted(value):
            lines.append(
                f"{child_indent}{json.dumps(str(key))} = "
                f"{render_nix_value(value[key], indent + 1)};"
            )
        lines.append(f"{current_indent}}}")
        return "\n".join(lines)
    if isinstance(value, list):
        if not value:
            return "[]"
        return "[ " + " ".join(render_nix_value(item, indent) for item in value) + " ]"
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value)
    die(f"unsupported bootstrap host value: {value!r}")


def render_bootstrap_hosts(hosts):
    return render_nix_value(hosts) + "\n"


def read_bootstrap_hosts(bootstrap_path):
    if not bootstrap_path.exists():
        return {}
    output = run_capture(["nix", "eval", "--json", "--file", bootstrap_path])
    try:
        hosts = json.loads(output)
    except json.JSONDecodeError as exc:
        die(f"could not parse bootstrap hosts JSON from {bootstrap_path}: {exc}")
    if not isinstance(hosts, dict):
        die(f"bootstrap hosts file must evaluate to an attrset: {bootstrap_path}")
    for host, entry in hosts.items():
        if not isinstance(host, str) or not isinstance(entry, dict):
            die(f"bootstrap host entries must be attrsets keyed by host name: {host!r}")
    return hosts


def updated_bootstrap_hosts(hosts, host):
    updated = dict(hosts)
    entry = dict(updated.get(host, {}))
    entry.pop("on", None)
    entry["state"] = "on"
    updated[host] = entry
    return updated


def write_bootstrap_hosts(repo_root, host):
    bootstrap_path = repo_root / "lib" / "services" / "migrator" / "bootstrap-hosts.nix"
    hosts = read_bootstrap_hosts(bootstrap_path)
    bootstrap_path.write_text(
        render_bootstrap_hosts(updated_bootstrap_hosts(hosts, host)),
        encoding="utf-8",
    )


def nixbot_dirty_flag():
    return os.environ.get("MIGRATOR_NIXBOT_DIRTY_FLAG", DEFAULT_NIXBOT_DIRTY_FLAG)


def deploy_target_prepared(args, host):
    if args.skip_deploy:
        info(f"skip-deploy: would deploy drained target generation for {host}")
        return

    tmp_root = Path(args.repo_root) / "tmp" / f"data-migrator.{os.getpid()}"
    worktree = tmp_root / f"{host}-prepare"
    if worktree.exists():
        shutil.rmtree(worktree)
    run(
        ["git", "worktree", "add", "--detach", worktree, "HEAD"],
        cwd=args.repo_root,
        dry_run=args.dry_run,
    )
    deploy_succeeded = False
    try:
        if args.dry_run:
            info(
                f"dry-run: would write migrator bootstrap host override for {host} in {worktree}"
            )
        else:
            write_bootstrap_hosts(worktree, host)
            run(
                ["git", "add", "lib/services/migrator/bootstrap-hosts.nix"],
                cwd=worktree,
            )
        nixbot = [
            "nixbot",
            "deploy",
            "--hosts",
            host,
            nixbot_dirty_flag(),
            "--force",
        ]
        if args.nixbot_goal:
            nixbot.extend(["--goal", args.nixbot_goal])
        if args.nixbot_dry:
            nixbot.append("--dry")
        run(nixbot, cwd=worktree, dry_run=args.dry_run)
        deploy_succeeded = True
    finally:
        if deploy_succeeded and not args.keep_workdir and not args.dry_run:
            run(
                ["git", "worktree", "remove", "--force", worktree],
                cwd=args.repo_root,
            )
            shutil.rmtree(tmp_root, ignore_errors=True)
        elif not deploy_succeeded and not args.dry_run:
            info(f"kept failed bootstrap worktree for inspection: {worktree}")


def deploy_target_resumed(args, host):
    if args.skip_deploy:
        info(
            f"skip-deploy: would deploy normal target generation and turn gate off for {host}"
        )
        return

    nixbot = [
        "nixbot",
        "deploy",
        "--hosts",
        host,
        nixbot_dirty_flag(),
        "--force",
    ]
    if args.nixbot_goal:
        nixbot.extend(["--goal", args.nixbot_goal])
    if args.nixbot_dry:
        nixbot.append("--dry")
    run(nixbot, cwd=args.repo_root, dry_run=args.dry_run)
    deploy_drain(args, host, False)


def deploy_drain(args, host, enabled):
    state = "on" if enabled else "off"
    if args.skip_deploy:
        info(f"skip-deploy: would set services.migrator gate {state} for {host}")
        return

    cmd = [
        "migratorctl",
        "remote",
        state,
        "--host",
        host,
        "--repo-root",
        str(args.repo_root),
    ]
    run(cmd, cwd=args.repo_root, dry_run=args.dry_run or args.nixbot_dry)


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="data-migrator",
        description="Migrate declared host data with rsync, an optional drained target bootstrap deploy, and runtime migrator gate toggles.",
    )
    parser.add_argument(
        "--profile",
        required=True,
        help="profile from pkgs/tools/data-migrator/profiles.nix",
    )
    parser.add_argument("--config", help="explicit migration YAML path")
    parser.add_argument(
        "--source-host",
        help="source SSH host used by rsync; defaults to profile source_host",
    )
    parser.add_argument("--target-host", help="target SSH host used by rsync")
    parser.add_argument("--target-dir", help="local destination base directory")
    parser.add_argument(
        "--source-base",
        help="source path base used to map paths onto the target path base",
    )
    parser.add_argument(
        "--target-base",
        help="target path base; defaults to config target_path_base or /var/lib/abird",
    )
    parser.add_argument(
        "--transport",
        choices=["auto", "rsync", "tar"],
        default="auto",
        help="file-copy transport; auto prefers rsync and falls back to tar",
    )
    parser.add_argument(
        "--copy-mode",
        choices=["pull", "push"],
        default="pull",
        help="pull runs rsync on target; push runs rsync on source",
    )
    parser.add_argument(
        "--warm",
        action="store_true",
        help="only run the seed copy; do not bootstrap the target or toggle migrator drain state",
    )
    parser.add_argument(
        "--source-drain-host",
        help="nixbot host to drain before final copy; defaults to --source-host",
    )
    parser.add_argument(
        "--target-drain-host",
        help="nixbot host to drain/resume; defaults to --target-host",
    )
    parser.add_argument(
        "--skip-source-drain",
        action="store_true",
        help="allow a final copy without draining the source host",
    )
    parser.add_argument(
        "--no-resume-target",
        action="store_true",
        help="leave the target host drained after final copy",
    )
    parser.add_argument(
        "--resume-source",
        action="store_true",
        help="resume the source host after final copy",
    )
    parser.add_argument(
        "--skip-deploy",
        action="store_true",
        help="do not bootstrap the target or call migratorctl; useful when hosts are already deployed and in the desired drain state",
    )
    parser.add_argument(
        "--nixbot-goal",
        default="switch",
        help="goal passed to the drained target bootstrap nixbot deploy",
    )
    parser.add_argument(
        "--nixbot-dry",
        action="store_true",
        help="treat the bootstrap deploy and migratorctl runtime drain calls as dry-run",
    )
    parser.add_argument("--repo-root", help="repo root; auto-detected by default")
    parser.add_argument(
        "--rsync-ssh",
        help="rsync remote shell command passed as -e, for example 'ssh -J gap3-gondor'",
    )
    parser.add_argument(
        "--source-rsync-path",
        default=default_source_rsync_path(),
        help="remote rsync path for source reads",
    )
    parser.add_argument(
        "--remote-sudo",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="use sudo for remote mkdir/rsync",
    )
    parser.add_argument(
        "--local-sudo",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="use sudo for local target directory creation",
    )
    parser.add_argument(
        "--incus-instance",
        "--source-instance",
        dest="incus_instance",
        help="Incus instance to migrate; defaults to profile name in Incus mode",
    )
    parser.add_argument(
        "--target-instance",
        help="destination Incus instance name; defaults to source instance name",
    )
    parser.add_argument("--source-project", help="source Incus project")
    parser.add_argument("--target-project", help="destination Incus project")
    parser.add_argument(
        "--incus-controller-host",
        help="SSH host that should run Incus client commands",
    )
    parser.add_argument("--incus-remote", help="source Incus remote; defaults to local")
    parser.add_argument(
        "--target-incus-remote",
        help="destination Incus remote; defaults to --incus-remote",
    )
    parser.add_argument(
        "--target-storage-pool",
        help="destination storage pool; defaults to source root disk pool",
    )
    parser.add_argument(
        "--incus-migration-mode",
        choices=["auto", "incus-native", "files"],
        default="auto",
        help="auto uses native btrfs snapshot refresh when possible, otherwise file copy",
    )
    parser.add_argument(
        "--incus-copy-mode",
        choices=["pull", "push", "relay"],
        default="pull",
        help="Incus transfer mode for native copies",
    )
    parser.add_argument(
        "--incus-stop-timeout",
        type=int,
        default=60,
        help="seconds to wait for graceful source instance shutdown",
    )
    parser.add_argument(
        "--snapshot-prefix",
        default="data-migrator",
        help="prefix for temporary Incus snapshots",
    )
    parser.add_argument(
        "--incus-stateless",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="copy stateful instances stateless",
    )
    parser.add_argument(
        "--incus-allow-inconsistent",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="allow live seed copy inconsistencies; final copy is taken after source stop",
    )
    parser.add_argument(
        "--force-refresh-existing",
        action="store_true",
        help="allow refreshing an existing target without a matching migrator marker",
    )
    parser.add_argument(
        "--leave-source-running",
        action="store_true",
        help="restart source instance after the final copy",
    )
    parser.add_argument(
        "--no-start-target",
        action="store_true",
        help="do not start the target instance after the final copy",
    )
    parser.add_argument(
        "--dry-run", action="store_true", help="print commands without running them"
    )
    parser.add_argument(
        "--keep-workdir",
        action="store_true",
        help="keep the temporary drained target bootstrap worktree for inspection",
    )
    args = parser.parse_args(argv)
    args.incus_mode = bool(
        args.incus_instance
        or args.target_instance
        or args.source_project
        or args.target_project
    )
    if not args.incus_mode and bool(args.target_host) == bool(args.target_dir):
        die("pass exactly one of --target-host or --target-dir")
    if args.incus_mode and args.target_host and args.target_dir:
        die("pass at most one of --target-host or --target-dir")
    if args.target_dir and args.copy_mode != "pull":
        die("--target-dir only supports --copy-mode pull")
    if args.no_start_target and not args.no_resume_target:
        die("--no-start-target requires --no-resume-target")
    return args


def main(argv):
    args = parse_args(argv)
    args.repo_root = str(find_repo_root(args.repo_root or os.getcwd()))
    _, plan = load_plan(Path(args.repo_root), args.profile, args.config)
    args.source_host = args.source_host or plan_string(plan, "source_host")
    if args.incus_mode:
        migrate_incus_instance(args, plan)
        return

    if not args.source_host:
        die("pass --source-host or set source_host in the data-migrator profile")
    args.effective_transport = resolve_transport(args)

    if args.warm:
        migrate_paths(args, plan, "warm")
        return

    target_drain_host = (
        args.target_drain_host
        or plan_string(plan, "target_drain_host")
        or args.target_host
    )
    source_drain_host = (
        args.source_drain_host
        or plan_string(plan, "source_drain_host")
        or args.source_host
    )
    if not target_drain_host and not args.skip_deploy:
        die("full migration to --target-dir needs --target-drain-host or --skip-deploy")
    if not args.skip_source_drain and not source_drain_host:
        die("full migration needs --source-drain-host or --skip-source-drain")

    if target_drain_host:
        deploy_target_prepared(args, target_drain_host)
        deploy_drain(args, target_drain_host, True)
    migrate_paths(args, plan, "seed")
    if not args.skip_source_drain:
        deploy_drain(args, source_drain_host, True)
    migrate_paths(args, plan, "final")
    if target_drain_host and not args.no_resume_target:
        deploy_target_resumed(args, target_drain_host)
    if args.resume_source and not args.skip_source_drain:
        deploy_drain(args, source_drain_host, False)


if __name__ == "__main__":
    main(sys.argv[1:])
