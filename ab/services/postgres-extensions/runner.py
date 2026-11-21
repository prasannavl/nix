#!/usr/bin/env python3
"""Explicit, restartable migrations for installed PostgreSQL extensions.

The release policy is reviewed with the image. This command is deliberately
not a container entrypoint or activation hook. No credentials are extracted.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import select
import signal
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path


LOCK_ID = 728094531276001


def literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def identifier(value: str) -> str:
    return '"' + value.replace('"', '""') + '"'


def connection_database(value: str) -> str:
    # psql interprets dbnames containing '=' or a URI prefix as connection
    # strings. Always supply a quoted libpq dbname value, including such names.
    return "dbname='" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def stop_process_group(process: subprocess.Popen) -> None:
    # A command prefix may be a wrapper with SSH/ProxyCommand children. Killing
    # only its immediate PID can leave the actual database connection alive.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=5)


def run_command(command: list[str], timeout: int, guard=None) -> subprocess.CompletedProcess:
    process = subprocess.Popen(command, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    deadline = time.monotonic() + timeout
    try:
        while True:
            if guard is not None and guard.poll() is not None:
                raise RuntimeError("Migration lock connection was lost during SQL execution")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, timeout)
            try:
                stdout, stderr = process.communicate(timeout=min(0.25, remaining))
                if guard is not None and guard.poll() is not None:
                    raise RuntimeError("Migration lock connection was lost during SQL execution")
                return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
            except subprocess.TimeoutExpired:
                continue
    except BaseException:
        stop_process_group(process)
        raise


def numeric_version(version):
    if not isinstance(version, str) or not re.fullmatch(r"\d+(?:\.\d+)+", version):
        return None
    return tuple(map(int, version.split(".")))


def upgrade_from(rule: dict):
    if "upgradeFrom" in rule and "sources" in rule:
        raise ValueError("Policy may use upgradeFrom or legacy sources, not both")
    return rule.get("upgradeFrom", rule.get("sources"))


def validate_policy(policy: dict) -> None:
    if not isinstance(policy.get("image"), str) or not policy["image"]:
        raise ValueError("Policy must pin the container image")
    if not isinstance(policy.get("postgresMajor"), int):
        raise ValueError("Policy must pin the PostgreSQL major")
    if not isinstance(policy.get("extensions"), dict) or not policy["extensions"]:
        raise ValueError("Policy must pin extension targets")
    for name, rule in policy["extensions"].items():
        if not re.fullmatch(r"[a-z][a-z0-9_]*", name):
            raise ValueError(f"Invalid extension name: {name}")
        if not isinstance(rule, dict):
            raise ValueError(f"Extension policy must be an object: {name}")
        unknown = set(rule) - {"target", "upgradeFrom", "sources"}
        if unknown:
            raise ValueError(f"Unsupported extension policy fields for {name}: {sorted(unknown)}")
        target = rule.get("target")
        target_version = numeric_version(target)
        if target_version is None:
            raise ValueError(f"Extension target must be an explicit numeric version: {name}")
        allowed = upgrade_from(rule)
        if allowed is None:
            continue
        if not isinstance(allowed, list) or not allowed:
            raise ValueError(f"upgradeFrom must be a non-empty version list: {name}")
        versions = [numeric_version(version) for version in allowed]
        if any(version is None for version in versions):
            raise ValueError(f"upgradeFrom must contain numeric versions: {name}")
        if any(current >= following for current, following in zip(versions, versions[1:])):
            raise ValueError(f"upgradeFrom must be strictly increasing: {name}")
        if any(version >= target_version for version in versions):
            raise ValueError(f"upgradeFrom versions must be older than target: {name}")


def migration_order(installed: dict, dependencies: list, policy: dict) -> list[str]:
    selected = set(installed) & set(policy["extensions"])
    # Timescale must precede toolkit even where its dependency is not catalogued.
    edges = [(name, dep) for name, dep in dependencies if name in selected and dep in selected]
    if {"timescaledb", "timescaledb_toolkit"} <= selected:
        edges.append(("timescaledb_toolkit", "timescaledb"))
    result = []
    while selected:
        ready = sorted(name for name in selected if not any(
            child == name and parent in selected for child, parent in edges
        ))
        if not ready:
            raise RuntimeError("Cyclic extension dependencies")
        result.extend(ready)
        selected.difference_update(ready)
    return result


class Database:
    def __init__(self, podman: list[str], container: str, user: str, timeout: int):
        self.podman = podman
        self.container = container
        self.user = user
        self.timeout = timeout
        self.guard = None
        self.guard_pid = None

    def command(self, db: str, readonly: bool = True) -> list[str]:
        options = f"-c lock_timeout=10000 -c statement_timeout={self.timeout * 1000}"
        if readonly:
            options += " -c default_transaction_read_only=on"
        return [*self.podman, "exec", "-i", self.container, "env", f"PGOPTIONS={options}",
                "psql", "-X", "-w", "-U", self.user, "--dbname", connection_database(db),
                "-At", "-v", "ON_ERROR_STOP=1", "-P", "pager=off"]

    def sql(self, db: str, sql: str, readonly: bool = True) -> str:
        if not readonly:
            self.check_lock()
        # -c supplies exactly one command in a fresh -X session. In particular,
        # no catalog query precedes ALTER EXTENSION timescaledb in that session.
        result = run_command([*self.command(db, readonly), "-c", sql], self.timeout + 15,
                             None if readonly else self.guard)
        if result.returncode:
            raise RuntimeError(f"{db}: psql failed: {result.stderr.strip()}")
        if result.stderr:
            print(result.stderr.strip(), file=sys.stderr)
        return result.stdout.strip()

    def query(self, db: str, sql: str):
        return json.loads(self.sql(db, sql))

    def check_lock(self):
        if self.guard is None or self.guard.poll() is not None or self.guard_pid is None:
            raise RuntimeError("Migration lock connection is not alive")
        # An idle psql transport can remain alive after its server backend dies.
        # Verify the actual backend still owns the advisory lock before writes.
        held = self.query("postgres", f"""
SELECT to_json(EXISTS(SELECT FROM pg_locks
 WHERE locktype='advisory' AND granted AND objsubid=1 AND mode='ExclusiveLock' AND pid={self.guard_pid}
 AND classid={LOCK_ID >> 32} AND objid={LOCK_ID & 0xffffffff}));
""")
        if held is not True:
            raise RuntimeError("Server backend no longer owns the migration lock")

    @contextmanager
    def lock(self):
        # A dedicated connection owns the cluster-wide cooperative lock through
        # all fresh upgrade sessions. EOF/crash releases it without a stamp.
        guard = subprocess.Popen(self.command("postgres"), stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                 start_new_session=True)
        self.guard = guard
        try:
            guard.stdin.write(f"SELECT json_build_array(pg_try_advisory_lock({LOCK_ID}), pg_backend_pid());\n")
            guard.stdin.flush()
            if not select.select([guard.stdout], [], [], 15)[0]:
                raise RuntimeError("Timed out acquiring migration lock")
            acquired, backend_pid = json.loads(guard.stdout.readline())
            if acquired is not True or type(backend_pid) is not int or backend_pid < 1:
                raise RuntimeError("Another migration owns the lock, or lock acquisition failed")
            self.guard_pid = backend_pid
            yield
        finally:
            try:
                try:
                    guard.stdin.close()
                except BrokenPipeError:
                    pass
                guard.stdin = None
                try:
                    guard.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    pass
            finally:
                try:
                    # The leader can exit before its transport children. Always
                    # clean the group, even when wait() has already succeeded.
                    stop_process_group(guard)
                finally:
                    guard.stdout.close()
                    guard.stderr.close()
                    self.guard = None
                    self.guard_pid = None

    def check_image(self, image: str):
        result = run_command([*self.podman, "inspect", "--format", "{{.Config.Image}}", self.container], 15)
        if result.returncode:
            raise RuntimeError(f"Container inspection failed: {result.stderr.strip()}")
        if result.stdout.strip() != image:
            raise RuntimeError(f"Live image differs from release policy: {result.stdout.strip()}")


def inventory(database: Database, db: str) -> dict:
    return database.query(db, """
SELECT json_build_object(
  'major', current_setting('server_version_num')::int / 10000,
  'installed', (SELECT json_object_agg(extname, extversion) FROM pg_extension),
  'dependencies', (SELECT coalesce(json_agg(json_build_array(e.extname, r.extname)), '[]')
    FROM pg_depend d JOIN pg_extension e ON d.classid='pg_extension'::regclass AND d.objid=e.oid
    JOIN pg_extension r ON d.refclassid='pg_extension'::regclass AND d.refobjid=r.oid));
""")


def plan(database: Database, policy: dict) -> list[dict]:
    databases = database.query("postgres", """
SELECT coalesce(json_agg(datname ORDER BY datname), '[]') FROM pg_database WHERE datallowconn;
""")
    result = []
    for db in databases:
        state = inventory(database, db)
        if state["major"] != policy["postgresMajor"]:
            raise RuntimeError(f"{db}: PostgreSQL major differs from policy")
        for name in migration_order(state["installed"], state["dependencies"], policy):
            source = state["installed"][name]
            rule = policy["extensions"][name]
            target = rule["target"]
            source_version = numeric_version(source)
            target_version = numeric_version(target)
            if source_version is None:
                raise RuntimeError(f"{db}/{name}: installed version is not numeric: {source}")
            if source_version > target_version:
                raise RuntimeError(
                    f"{db}/{name}: installed version {source} is newer than target {target}; "
                    "downgrade prohibited"
                )
            allowed = upgrade_from(rule)
            if source != target and allowed is not None and source not in allowed:
                raise RuntimeError(
                    f"{db}/{name}: installed version {source} is not permitted by "
                    f"upgradeFrom for target {target}"
                )
            path = database.query(db, f"""
SELECT json_build_object(
  'available', EXISTS(SELECT FROM pg_available_extension_versions
    WHERE name={literal(name)} AND version={literal(target)}),
  'path', (SELECT path FROM pg_extension_update_paths({literal(name)})
    WHERE source={literal(source)} AND target={literal(target)}));
""")
            if not path["available"] or (source != target and not path["path"]):
                raise RuntimeError(f"{db}/{name}: missing target or update path {source} -> {target}")
            result.append({"database": db, "extension": name, "source": source,
                           "target": target, "path": path["path"], "update": source != target})
    return result


def migrate(database: Database, policy: dict, apply: bool) -> list[dict]:
    validate_policy(policy)
    database.check_image(policy["image"])
    with database.lock():
        steps = plan(database, policy)  # All databases must pass before any writes.
        print(json.dumps({"mode": "apply" if apply else "plan", "steps": steps}), flush=True)
        if not apply:
            return steps
        for step in steps:
            if not step["update"]:
                continue
            db, name, target = step["database"], step["extension"], step["target"]
            actual = inventory(database, db)["installed"].get(name)
            if actual != step["source"]:
                raise RuntimeError(f"{db}/{name}: catalog changed after planning; rerun the plan")
            database.sql(db, f"ALTER EXTENSION {identifier(name)} UPDATE TO {literal(target)};", False)
            if inventory(database, db)["installed"].get(name) != target:
                raise RuntimeError(f"{db}/{name}: upgrade completion verification failed")
            print(json.dumps({"completed": f"{db}/{name}", "version": target}), flush=True)
        remaining = plan(database, policy)
        if any(step["update"] for step in remaining):
            raise RuntimeError("Extensions remain behind policy after migration")
        print(json.dumps({"verified": True, "steps": remaining}), flush=True)
        return remaining


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--container", required=True)
    parser.add_argument("--user", default="postgres")
    parser.add_argument("--podman-command-json", default='["podman"]',
                        help="Argument array for an optional Podman transport wrapper; no shell evaluation")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--apply", action="store_true", help="Execute the reviewed policy; default only plans")
    args = parser.parse_args()
    try:
        command = json.loads(args.podman_command_json)
        if not isinstance(command, list) or not command or not all(isinstance(x, str) for x in command):
            raise ValueError("Podman command must be a nonempty string argument array")
        if args.timeout < 1:
            raise ValueError("Timeout must be positive")
        migrate(Database(command, args.container, args.user, args.timeout),
                json.loads(args.policy.read_text()), args.apply)
    except (ValueError, KeyError, OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Migration stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
