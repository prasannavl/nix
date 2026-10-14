#!/usr/bin/env python3
"""Explicit, read-only CLI semantic acceptance; importing never runs a binary.

The caller supplies an already admitted binary/final handle and expectations.
This runner neither realizes Nix outputs nor grants native execution authority.
Filesystem absence observations are not syscall/data-read or effect proofs.
"""

import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import stat
import subprocess
import time

import fixture


TIMEOUT_SECONDS = 10
MAX_LOG_BYTES = 1024 * 1024
MAX_SPEC_BYTES = 1024 * 1024
DATA_TOKEN = "@owned-data@"


class Failure(Exception):
    """Fail-closed semantic or execution failure."""


def _json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    def invalid(value):
        raise ValueError(f"non-JSON constant: {value}")

    try:
        return json.loads(data, object_pairs_hook=unique, parse_constant=invalid)
    except (ValueError, UnicodeError, RecursionError) as error:
        raise Failure(f"malformed JSON: {error}") from error


def _validate(binary, final, expected):
    if not isinstance(final, dict) or set(final) != {
        "derivationPath", "output", "storePath"
    }:
        raise Failure("final must be an explicit identity triple")
    for key in ("derivationPath", "storePath"):
        value = final[key]
        if not isinstance(value, str) or not value.startswith("/nix/store/"):
            raise Failure(f"invalid final {key}")
        if len(Path(value).parts) != 4 or "/../" in value:
            raise Failure(f"invalid final {key}")
    if not final["derivationPath"].endswith(".drv") or final["output"] != "out":
        raise Failure("only an explicit out derivation handle is supported")
    binary = os.fspath(binary)
    prefix = final["storePath"] + "/bin/"
    if not binary.startswith(prefix) or "/" in binary[len(prefix):] or not binary[len(prefix):]:
        raise Failure("binary must be directly beneath the final handle's bin directory")
    keys = {"schemaVersion", "versionStdout", "resourceId", "missingResourceId",
            "operation", "resourceManifest"}
    if not isinstance(expected, dict) or set(expected) != keys:
        raise Failure("invalid expected specification keys")
    if type(expected["schemaVersion"]) is not int or expected["schemaVersion"] != 1:
        raise Failure("unsupported expected specification schema")
    for key in ("versionStdout", "resourceId", "missingResourceId", "operation"):
        if not isinstance(expected[key], str) or not expected[key] or "\x00" in expected[key]:
            raise Failure(f"invalid expected {key}")
    if expected["resourceId"] == expected["missingResourceId"]:
        raise Failure("missing resource must differ from accepted resource")
    manifest = expected["resourceManifest"]
    required = {"schema_version": 1, "resources": [
        {"id": expected["resourceId"], "data_paths": [DATA_TOKEN]},
    ]}
    if manifest != required or type(manifest.get("schema_version")) is not int:
        raise Failure("manifest must declare exactly one owned, absent data path")
    return binary


def _execute(command, cwd, timeout, log_limit, stage_fd):
    """Bound pipe reads while running, not after unbounded capture_output."""
    stdout, stderr = bytearray(), bytearray()
    problem = None
    environment = {"PATH": "/does/not/exist", "LANG": "C", "LC_ALL": "C",
                   "HOME": str(cwd / "home"), "TMPDIR": str(cwd)}
    process = subprocess.Popen(
        command, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
        pass_fds=(stage_fd,),
    )
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as selector:
            for pipe, buffer in ((process.stdout, stdout), (process.stderr, stderr)):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, buffer)
            while selector.get_map() or process.poll() is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    problem = "timeout"
                    break
                for key, _event in selector.select(min(remaining, 0.05)):
                    # Read at most one byte beyond the limit to detect overflow.
                    budget = log_limit - len(stdout) - len(stderr)
                    chunk = os.read(key.fd, min(65536, budget + 1))
                    if not chunk:
                        selector.unregister(key.fileobj)
                    elif len(chunk) > budget:
                        key.data.extend(chunk[:budget])
                        problem = "log byte limit exceeded"
                        break
                    else:
                        key.data.extend(chunk)
                if problem:
                    break
        if problem:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        code = process.wait(timeout=max(0.01, deadline - time.monotonic()))
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=1)
        raise
    finally:
        process.stdout.close()
        process.stderr.close()
    return code, bytes(stdout), bytes(stderr), problem


def _checked_destination(output, output_root):
    raw = os.fspath(output)
    root_raw = os.fspath(output_root)
    for value in (raw, root_raw):
        if not value or "\x00" in value:
            raise Failure("output and output root must be nonempty paths")
        if any(p == ".." or p == "secrets" or p.endswith(".key") for p in Path(value).parts):
            raise Failure("unsafe output path")
    root = Path(os.path.abspath(root_raw))
    destination = Path(os.path.abspath(raw))
    if not destination.is_relative_to(root) or destination == root:
        raise Failure("output must be a fresh directory beneath the explicit output root")
    return destination


def _same_inode(left, right):
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def _require_bindings(bindings):
    """Reject changed ancestor/stage entries, never follow their replacements."""
    for parent, name, descriptor in bindings:
        try:
            entry = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except OSError as error:
            raise Failure("output directory binding changed") from error
        if not stat.S_ISDIR(entry.st_mode) or not _same_inode(entry, os.fstat(descriptor)):
            raise Failure("output directory binding changed")


def _write_owned(directory, name, data):
    """No pre-existing entry, including a regular hardlink, may be overwritten."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    descriptor = os.open(name, flags, 0o600, dir_fd=directory)
    with os.fdopen(descriptor, "wb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise Failure("evidence file must be a new unaliased regular file")
        stream.write(data)


def _write_json(directory, name, value):
    _write_owned(directory, name, (json.dumps(value, indent=2) + "\n").encode())


def _exists_owned(directory, name):
    try:
        os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return True


def _directory_names(directory):
    # Reopen the anchored inode: overlay directory streams may have cached the
    # entries present when the original FD was opened, before CLI writes.
    descriptor = os.open(".", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                         dir_fd=directory)
    try:
        with os.scandir(descriptor) as entries:
            return [entry.name for entry in entries]
    finally:
        os.close(descriptor)


def _cleanup_owned_stage(parent, directory):
    """Clean only the opened stage; a swapped pathname grants no authority.

    Recursive removal uses Python's symlink-safe dir_fd implementation. A stage
    renamed out of the opened parent may remain empty; never chase it by path.
    """
    for name in _directory_names(directory):
        info = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            if not shutil.rmtree.avoids_symlink_attacks:
                raise Failure("descriptor-safe recursive cleanup is required")
            shutil.rmtree(name, dir_fd=directory)
        else:
            os.unlink(name, dir_fd=directory)
    owned = os.fstat(directory)
    for name in _directory_names(parent):
        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode) and _same_inode(info, owned):
            os.rmdir(name, dir_fd=parent)
            break


def _read_regular_json(path):
    """Bound input reads and open each component without following aliases."""
    raw = os.fspath(path)
    if not raw or "\x00" in raw or any(
        p == ".." or p == "secrets" or p.endswith(".key") for p in Path(raw).parts
    ):
        raise Failure("unsafe specification path")
    absolute = Path(os.path.abspath(raw))
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    with ExitStack() as descriptors:
        parent = os.open("/", flags)
        descriptors.callback(os.close, parent)
        for part in absolute.parts[1:-1]:
            parent = os.open(part, flags, dir_fd=parent)
            descriptors.callback(os.close, parent)
        file_fd = os.open(absolute.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                          dir_fd=parent)
        descriptors.callback(os.close, file_fd)
        if not stat.S_ISREG(os.fstat(file_fd).st_mode):
            raise Failure("specification must be a regular file")
        with os.fdopen(file_fd, "rb", closefd=False) as stream:
            data = stream.read(MAX_SPEC_BYTES + 1)
            if len(data) > MAX_SPEC_BYTES:
                raise Failure("specification byte limit exceeded")
    return _json(data)


def run_acceptance(binary, final, expected, output, *, output_root=fixture.TMP_ROOT):
    """Run only version/describe/missing cases and atomically publish raw evidence.

    The output root and all parents must already exist, without symlinks.
    Default output fence is repository tmp; Nix supplies its own build directory.
    On failure only our private stage is removed; no success output is published.
    Binary binding here is lexical; actual derivation equality is enforced by Nix
    before serialization, not certified by a caller-provided JSON handle.
    """
    binary = _validate(binary, final, expected)
    destination = _checked_destination(output, output_root)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    with ExitStack() as directories:
        def open_dir(name, parent=None):
            descriptor = os.open(name, flags, dir_fd=parent)
            directories.callback(os.close, descriptor)
            return descriptor

        parent = open_dir("/")
        bindings = []
        for part in destination.parts[1:-1]:
            descriptor = open_dir(part, parent)
            bindings.append((parent, part, descriptor))
            parent = descriptor
        name = destination.name
        try:
            os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise FileExistsError(f"output already exists: {destination}")
        stage_name = fixture._create_stage(parent)
        stage_fd = open_dir(stage_name, parent)
        bindings.append((parent, stage_name, stage_fd))
        # The child inherits only this FD. CLI paths/cwd are anchored too, not
        # absolute staging paths whose ancestors it could replace with links.
        stage = Path(f"/proc/self/fd/{stage_fd}")
        published = False
        try:
            _require_bindings(bindings)
            state, data = stage / "state", stage / "data-not-created"
            manifest = {"schema_version": 1, "resources": [
                {"id": expected["resourceId"], "data_paths": [str(data)]},
            ]}
            manifest_path = stage / "resources.json"
            _write_json(stage_fd, "resources.json", manifest)
            common = [binary, "--json", "--resource-manifest", str(manifest_path),
                      "--state-dir", str(state), "--systemctl", "/does/not/exist",
                      "--journalctl", "/does/not/exist", "--runuser", "/does/not/exist"]
            observations = []

            def run(case, command, expected_code):
                _require_bindings(bindings)
                code, stdout, stderr, problem = _execute(
                    command, stage, TIMEOUT_SECONDS, MAX_LOG_BYTES, stage_fd
                )
                _require_bindings(bindings)
                _write_owned(stage_fd, f"{case}.stdout", stdout)
                _write_owned(stage_fd, f"{case}.stderr", stderr)
                observation = {"case": case, "argv": command, "cwd": str(stage),
                               "exitCode": code,
                               "stdoutBytes": len(stdout), "stderrBytes": len(stderr),
                               "executionError": problem,
                               "stateExists": _exists_owned(stage_fd, "state"),
                               "declaredDataExists": _exists_owned(stage_fd, "data-not-created")}
                observations.append(observation)
                _write_json(stage_fd, f"{case}.json", observation)
                if problem or code != expected_code:
                    raise Failure(f"{case}: {problem or f'unexpected exit {code}'}")
                if observation["stateExists"] or observation["declaredDataExists"]:
                    raise Failure(f"{case}: persistent state or declared data path created")
                return stdout, stderr

            version, _stderr = run("version", [binary, "--version"], 0)
            if version != expected["versionStdout"].encode():
                raise Failure("version: unexpected version stdout")
            describe, _stderr = run(
                "describe", common + ["resource", "describe", "--resource", expected["resourceId"]],
                0,
            )
            value = _json(describe)
            if not isinstance(value, dict) or value.get("ok") is not True:
                raise Failure("describe: status must be true")
            if value.get("operation") != expected["operation"]:
                raise Failure("describe: wrong operation")
            result = value.get("result")
            resource = result.get("resource") if isinstance(result, dict) else None
            if not isinstance(resource, dict) or resource.get("id") != expected["resourceId"]:
                raise Failure("describe: wrong resource")
            if resource.get("data_paths") != [str(data)]:
                raise Failure("describe: declared data path was not preserved")
            missing, missing_error = run(
                "missing", common + ["resource", "describe", "--resource",
                                     expected["missingResourceId"]], 1,
            )
            error_value = _json(missing_error)
            error_text = error_value.get("error") if isinstance(error_value, dict) else None
            if (missing or not isinstance(error_text, str)
                    or error_value.get("ok") is not False
                    or expected["missingResourceId"] not in error_text):
                raise Failure("missing: expected empty stdout and named resource error")
            summary = {"schemaVersion": 1, "final": final, "version": version.decode(),
                       "describe": value, "missingError": error_value, "cases": observations,
                       "caseCount": 3, "persistentStateAbsent": True,
                       "declaredDataPathAbsent": True,
                       "scope": "CLI semantics only; absence is not a data-read/effect proof",
                       "producer": {"qualified": False, "decision": "not_proven"},
                       "defaultAdoption": False}
            _write_json(stage_fd, "summary.json", summary)
            _require_bindings(bindings)
            fixture._publish_noreplace(parent, stage_name, name)
            bindings[-1] = (parent, name, stage_fd)
            _require_bindings(bindings)
            published = True
        finally:
            if not published:
                _cleanup_owned_stage(parent, stage_fd)
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--final", required=True, help="explicit final identity JSON file")
    parser.add_argument("--expected", required=True, help="expected specification JSON file")
    parser.add_argument("--output", required=True)
    parser.add_argument("--output-root", default=str(fixture.TMP_ROOT))
    args = parser.parse_args(argv)
    try:
        summary = run_acceptance(
            args.binary, _read_regular_json(args.final),
            _read_regular_json(args.expected), args.output, output_root=args.output_root,
        )
    except (Failure, OSError, subprocess.SubprocessError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
