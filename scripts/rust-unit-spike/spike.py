#!/usr/bin/env python3
"""Bounded local Cargo capability probe; not an exact unit-graph producer."""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time


CHECKOUT = Path(__file__).resolve().parents[2]
TMP_ROOT = CHECKOUT / "tmp"
MAX_BYTES = 2 * 1024 * 1024
EXACT_FIELDS = (
    "context", "package", "target", "role", "triple", "features", "profile",
    "rustflags", "edges", "build_script",
)
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


def encode(value):
    return json.dumps(value, sort_keys=True, indent=2, ensure_ascii=True) + "\n"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fingerprint(path):
    if not path.is_file():
        return {"path": str(path), "status": "unknown", "sha256": None}
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return {"path": str(path), "status": "observed", "sha256": hasher.hexdigest()}


def local_tool(name):
    found = shutil.which(name)
    if not found:
        raise ValueError(f"local executable not found: {name}")
    path = Path(found).resolve()
    # A rustup proxy could install the repository-selected toolchain.
    if path.name == "rustup":
        raise ValueError("rustup proxies are disallowed; select an installed binary directly")
    return path


def check_output(path):
    resolved = path.resolve()
    if (TMP_ROOT.resolve() != TMP_ROOT or not resolved.is_relative_to(TMP_ROOT)
            or resolved == TMP_ROOT):
        raise ValueError(f"output must be a subdirectory of {TMP_ROOT} without an escaping tmp root")
    if resolved != Path(os.path.abspath(path)):
        raise ValueError("output path must not contain symlinks")
    for name in ("cargo-home", "target", "runtime", "report.json"):
        if (path / name).is_symlink():
            raise ValueError(f"output child must not be a symlink: {name}")
    return resolved


def reject_report_alias(out, input_paths):
    report = out / "report.json"
    if report.exists():
        for path in input_paths:
            if path.exists() and report.samefile(path):
                raise ValueError(f"report.json aliases inspected input: {path}")


def output_folder(path):
    path = check_output(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        path.mkdir(mode=0o700)
    except FileExistsError as error:
        raise ValueError("output directory already exists; choose a fresh per-run directory") from error
    return path


def publish_report(out, report, input_paths):
    """Replace only the report directory entry, never truncate an existing inode."""
    check_output(out)
    reject_report_alias(out, input_paths)
    fd, name = tempfile.mkstemp(prefix=".report-", suffix=".json", dir=out)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(encode(report))
            stream.flush()
            os.fsync(stream.fileno())
        check_output(out)
        reject_report_alias(out, input_paths)
        os.replace(temporary, out / "report.json")
    finally:
        temporary.unlink(missing_ok=True)


def cleanup_child(child):
    """Kill even successfully orphaned group members; never wait indefinitely."""
    deadline = time.monotonic() + 1
    # SIGKILL needs no grace period and does not depend on child cooperation.
    # Retry interruptions during cleanup without swallowing the original exit.
    interrupted = None
    try:
        while True:
            try:
                os.killpg(child.pid, signal.SIGKILL)
                break
            except ProcessLookupError:
                break
            except (KeyboardInterrupt, SystemExit, InterruptedError) as error:
                interrupted = error
                if time.monotonic() >= deadline:
                    raise ValueError("process-group cleanup interrupted") from error
        while True:
            try:
                child.wait(timeout=max(0.001, deadline - time.monotonic()))
                break
            except (KeyboardInterrupt, SystemExit, InterruptedError) as error:
                interrupted = error
                if time.monotonic() >= deadline:
                    raise ValueError("child cleanup interrupted") from error
            except subprocess.TimeoutExpired as error:
                raise ValueError("child did not exit within the process-group cleanup bound") from error
    finally:
        child.stdout.close()
        child.stderr.close()
    if isinstance(interrupted, (KeyboardInterrupt, SystemExit)):
        raise interrupted


def probe(command, cwd, env, timeout, max_bytes=MAX_BYTES):
    """Bound output/wall time and clean the process group on every exit."""
    result = {"command": command, "status": "unknown", "returncode": None,
              "stdout": "", "stderr": ""}
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    try:
        child = subprocess.Popen(
            command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as error:
        result.update(status="unavailable", stderr=str(error))
        return result
    failure = None
    try:
        deadline = time.monotonic() + timeout
        total = 0
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ, "stdout")
            selector.register(child.stderr, selectors.EVENT_READ, "stderr")
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    failure = "timeout"
                    break
                for key, _ in selector.select(min(remaining, 0.1)):
                    data = os.read(key.fileobj.fileno(), 65536)
                    if not data:
                        selector.unregister(key.fileobj)
                        continue
                    kept = data[:max(0, max_bytes - total)]
                    buffers[key.data].extend(kept)
                    total += len(data)
                    if total > max_bytes:
                        failure = "output_limit"
                        break
                if failure:
                    break
        if not failure:
            try:
                child.wait(timeout=max(0.001, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                failure = "timeout"
    finally:
        cleanup_child(child)
    result.update(
        status=failure or ("ok" if child.returncode == 0 else "failed"),
        returncode=None if failure else child.returncode,
        **{key: value.decode("utf-8", errors="replace") for key, value in buffers.items()},
    )
    return result


def capability(result, token):
    if result["status"] != "ok":
        return "unknown"
    return "advertised" if token in result["stdout"] else "not_advertised"


def fidelity(source):
    # No supported collector in this spike attests exact producer fidelity.
    # In particular, caller-supplied 'exact' flags cannot qualify a producer.
    details = {
        "features": "Metadata feature definitions are not per-compilation feature sets.",
        "roles": "Artifact targets do not uniquely identify host/target compilation roles.",
        "edges": "Package dependencies are not typed compilation-unit edges.",
        "build_scripts": "Stable messages omit complete inputs, rerun state and effects.",
    }
    if source == "compiler_messages":
        details["features"] = (
            "Artifact features describe emitted artifacts, not a complete unit/edge graph."
        )
    return {key: {"status": "unknown", "exact": False, "reason": reason}
            for key, reason in details.items()}


def strings(value):
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def descriptor(unit):
    """Synthetic schema exercise only, not a trusted capture/import adapter.

    Every field must be explicitly exact and complete. No defaults or inferred
    roles/features/edges. Unit/demand and plan/capsule/lock freshness labels do
    not affect identity. Build-script results are build-time producer/input
    references, never evaluation-captured output values.
    """
    values = {}
    for name in EXACT_FIELDS:
        field = unit.get(name)
        if not isinstance(field, dict) or field.get("status") != "exact" or "value" not in field:
            raise ValueError(f"not exact: {name}")
        values[name] = copy.deepcopy(field["value"])
    context = values["context"]
    if not isinstance(context, dict) or set(context) != {"cargo", "rustc", "config"}:
        raise ValueError("incomplete context")
    if not all(isinstance(value, str) and SHA256.fullmatch(value) for value in context.values()):
        raise ValueError("invalid context digest")
    package = values["package"]
    if (not isinstance(package, dict) or set(package) != {"id", "source_digest"}
            or not isinstance(package["id"], str) or not package["id"]
            or not isinstance(package["source_digest"], str)
            or not SHA256.fullmatch(package["source_digest"])):
        raise ValueError("incomplete package identity")
    target = values["target"]
    if (not isinstance(target, dict) or set(target) != {"name", "kinds"}
            or not isinstance(target["name"], str) or not target["name"]
            or not strings(target["kinds"]) or not target["kinds"]):
        raise ValueError("incomplete target")
    if values["role"] not in ("host", "target", "build_script_compile", "build_script_run"):
        raise ValueError("invalid role")
    if not isinstance(values["triple"], str) or not values["triple"]:
        raise ValueError("missing explicit triple")
    if not strings(values["features"]) or not strings(values["rustflags"]):
        raise ValueError("invalid features or rustflags")
    if not isinstance(values["profile"], dict) or not values["profile"]:
        raise ValueError("missing explicit profile")
    edges = values["edges"]
    if not isinstance(edges, list):
        raise ValueError("missing edges")
    for edge in edges:
        if (not isinstance(edge, dict)
                or set(edge) != {"dependency_descriptor", "extern_name", "kind"}
                or not isinstance(edge["dependency_descriptor"], str)
                or not SHA256.fullmatch(edge["dependency_descriptor"])
                or not isinstance(edge["extern_name"], str) or not edge["extern_name"]
                or edge["kind"] not in ("normal", "build", "dev")):
            raise ValueError("incomplete edge")
    script = values["build_script"]
    if not isinstance(script, dict):
        raise ValueError("missing build-script applicability")
    if script != {"status": "not_applicable"}:
        if (set(script) != {"status", "inputs_identity", "result_producer_identity"}
                or script["status"] != "build_time_input"
                or not all(isinstance(script[key], str) and SHA256.fullmatch(script[key])
                           for key in ("inputs_identity", "result_producer_identity"))):
            raise ValueError("incomplete build-script build-time input identities")
    # Only semantically unordered fields are normalized. Rustflag order matters.
    values["features"] = sorted(set(values["features"]))
    values["target"] = {**target, "kinds": sorted(set(target["kinds"]))}
    values["edges"] = sorted(edges, key=encode)
    payload = encode(values)
    return {"sha256": digest(payload.encode()), "descriptor": values,
            "scope": "synthetic_schema_only", "producer_qualified": False}


def messages(text):
    counts = {"compiler-artifact": 0, "build-script-executed": 0}
    malformed = 0
    for line in text.splitlines():
        try:
            value = json.loads(line)
        except (ValueError, RecursionError):
            # JSON syntax, integer-conversion and nesting limits are evidence
            # failures. Keep this catch confined to the decoder itself.
            malformed += 1
            continue
        reason = value.get("reason") if isinstance(value, dict) else None
        if not isinstance(reason, str):
            malformed += 1
            continue
        if reason in counts:
            counts[reason] += 1
    return {"counts": counts, "malformed_lines": malformed,
            "exact_graph": False, "fidelity": fidelity("compiler_messages")}


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("probe", "capture-build"))
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--lockfile", type=Path)
    parser.add_argument("--cargo", default="cargo", help="installed Cargo binary, not rustup")
    parser.add_argument("--rustc", default="rustc", help="installed compiler, not rustup")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=10, help="seconds per child")
    parser.add_argument("--metadata-no-deps", action="store_true")
    parser.add_argument("--allow-expensive-build", action="store_true")
    parser.add_argument("--package", help="one package for the authorized build phase")
    args = parser.parse_args(argv)
    if args.timeout < 1 or args.timeout > 3600:
        parser.error("timeout must be between 1 and 3600 seconds")
    if args.phase == "probe" and args.timeout > 30:
        parser.error("cheap probes are limited to 30 seconds per child")
    if args.phase == "capture-build" and not args.allow_expensive_build:
        parser.error("capture-build requires explicit --allow-expensive-build authorization")
    if args.phase == "capture-build" and not args.package:
        parser.error("capture-build requires one --package")
    if args.phase == "probe" and (args.allow_expensive_build or args.package):
        parser.error("build options are not allowed in the cheap probe phase")
    return args


def run(args):
    repo = args.repo.resolve(strict=True)
    manifest = repo / "Cargo.toml"
    lock = (args.lockfile or repo / "Cargo.lock").resolve(strict=True)
    if not manifest.is_file():
        raise ValueError("--repo must contain Cargo.toml")
    if args.phase == "capture-build" and not repo.is_relative_to(TMP_ROOT):
        raise ValueError("authorized builds require an isolated repository under checkout tmp/")
    if (args.metadata_no_deps or args.phase == "capture-build") and lock != repo / "Cargo.lock":
        raise ValueError("stable execution requires the repository's own Cargo.lock")
    cargo, rustc = local_tool(args.cargo), local_tool(args.rustc)
    config_paths = [repo / path for path in (
        "rust-toolchain", "rust-toolchain.toml", ".cargo/config", ".cargo/config.toml",
    )]
    input_paths = [manifest, lock, cargo, rustc, *config_paths]
    reject_report_alias(args.output_dir, input_paths)
    out = output_folder(args.output_dir)
    # Isolated writable state. No inherited rustc wrappers or toolchain install.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("CARGO_", "RUST", "SCCACHE_"))}
    for folder in ("cargo-home", "target", "runtime"):
        (out / folder).mkdir(mode=0o700)
    env.update(CARGO_HOME=str(out / "cargo-home"), CARGO_TARGET_DIR=str(out / "target"),
               TMPDIR=str(out / "runtime"), TMP=str(out / "runtime"),
               TEMP=str(out / "runtime"), RUSTC=str(rustc),
               CARGO_NET_OFFLINE="true", CARGO_TERM_COLOR="never", LC_ALL="C")
    inputs = {"manifest": fingerprint(manifest), "lock": fingerprint(lock),
              "cargo_binary": fingerprint(cargo), "rustc_binary": fingerprint(rustc)}
    freshness = {"lock_sha256": inputs["lock"]["sha256"],
                 "scope": "plan_freshness_only_not_unit_identity"}
    inputs["repository_config"] = [fingerprint(path) for path in config_paths]
    commands = {
        "cargo_version": [str(cargo), "--version", "--verbose"],
        "rustc_version": [str(rustc), "-vV"],
        "metadata_help": [str(cargo), "metadata", "--help"],
        "build_help": [str(cargo), "build", "--help"],
        "unstable_help": [str(cargo), "-Z", "help"],
    }
    # Help probes run outside the selected repository to avoid its config.
    probes = {name: probe(cmd, out, env, min(args.timeout, 30))
              for name, cmd in commands.items()}
    report = {
        "schema_version": 1, "phase": args.phase, "repository": str(repo),
        "inputs": inputs, "plan_freshness": freshness, "probes": probes,
        "capabilities": {
            name: {"status": capability(probes["metadata_help"], f"--{name}"),
                   "evidence": "metadata_help"}
            for name in ("offline", "locked", "no-deps", "format-version", "filter-platform")
        },
        "stable_unit_graph": {"status": "unsupported", "exact": False,
                              "reason": "--unit-graph is unstable, not a stable capture API."},
        "metadata": {"status": "not_run", "package_level_only": True, "exact_graph": False},
        "compiler_messages": {"status": "not_run", "exact_graph": False},
        "fidelity": fidelity("metadata"),
        "producer": {"qualified": False, "decision": "not_proven",
                     "reason": "No trusted complete per-unit feature/role/edge/effect capture."},
        "canonicalization": {"status": "not_run", "eligible_exact_descriptors": 0},
        "context_gaps": [
            "Ancestor Cargo config and ambient non-Rust environment are not fully captured.",
            "Binary/lock fingerprints do not attest all source, native inputs or sysroot.",
            "No exact graph collector or compilation equivalence/reuse validation exists.",
        ],
        "existing_mechanisms": [
            {"inspected_checkout": str(CHECKOUT), "path": "lib/flake/pkg-helper.nix",
             "mechanism": "Crane cargoArtifacts archives", "exact_graph": False,
             "reason": "Artifact inheritance/joining is not an exact producer capture API."},
        ],
        "next_gate": {
            "authorization_required": True,
            "command_template": (
                "python3 -B scripts/rust-unit-spike/spike.py capture-build "
                "--repo tmp/rust-unit-spike/isolated-repo "
                "--package <package> --output-dir tmp/rust-unit-spike/build "
                "--timeout 600 --allow-expensive-build"
            ),
            "scope": "Offline locked single-job artifact evidence only; still not exact.",
            "environment_gate": "Externally enforce network denial and build-script containment.",
            "followup": "Authorize an exact capture adapter separately before producer qualification.",
        },
    }
    report["capabilities"]["json_build_messages"] = {
        "status": capability(probes["build_help"], "--message-format"),
        "evidence": "build_help", "executed": False,
    }
    if args.metadata_no_deps:
        cmd = [str(cargo), "metadata", "--offline", "--locked", "--no-deps",
               "--format-version", "1", "--manifest-path", str(manifest)]
        result = probe(cmd, repo, env, min(args.timeout, 30))
        probes["metadata_no_deps"] = result
        report["metadata"]["status"] = result["status"]
        if result["status"] == "ok":
            try:
                data = json.loads(result["stdout"])
            except (ValueError, RecursionError):
                report["metadata"]["status"] = "invalid_json"
            else:
                try:
                    report["metadata"].update(
                        package_count=len(data["packages"]),
                        resolve_present=data.get("resolve") is not None,
                        captured="workspace package definitions; not resolved compilation units",
                    )
                except (KeyError, TypeError):
                    report["metadata"]["status"] = "invalid_json"
    if args.phase == "capture-build":
        cmd = [str(cargo), "build", "--offline", "--locked", "--jobs", "1",
               "--package", args.package, "--message-format=json",
               "--manifest-path", str(manifest), "--target-dir", str(out / "target")]
        result = probe(cmd, repo, env, args.timeout)
        probes["authorized_build"] = result
        report["compiler_messages"] = {"status": result["status"], **messages(result["stdout"])}
        report["capabilities"]["json_build_messages"]["executed"] = True
        report["fidelity"] = fidelity("compiler_messages")
    report["lock_unchanged"] = fingerprint(lock) == inputs["lock"]
    report["manifest_unchanged"] = fingerprint(manifest) == inputs["manifest"]
    if not report["lock_unchanged"] or not report["manifest_unchanged"]:
        report["producer"]["reason"] = "Lock or manifest changed during probe; evidence invalid."
    # Recheck writable children after execution; build code is not sandboxed.
    publish_report(out, report, input_paths)
    return report


def main(argv=None):
    args = arguments(argv)
    try:
        report = run(args)
    except (OSError, ValueError) as error:
        print(f"rust-unit-spike: {error}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("rust-unit-spike: interrupted", file=sys.stderr)
        return 130
    print(str(args.output_dir.resolve() / "report.json"))
    return 0 if report["lock_unchanged"] and report["manifest_unchanged"] else 2


if __name__ == "__main__":
    sys.exit(main())
