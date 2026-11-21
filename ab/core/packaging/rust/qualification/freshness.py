#!/usr/bin/env python3
"""Bounded actual Cargo replay. Native execution requires separate lane approval.

Stdlib only. Importing this file never runs Cargo; fixture tests mock subprocess.
"""

import argparse
import hashlib
import json
import os
import re
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import tarfile
import time
from urllib.parse import unquote, urlsplit

import fixture


class Failure(ValueError):
    """Fail-closed readiness or observation error."""


def require(condition, message):
    if not condition:
        raise Failure(message)


def regular(path):
    path = Path(path)
    require(stat.S_ISREG(path.lstat().st_mode), f"not a regular file: {path}")
    return path


def digest(path):
    with regular(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def directory(path):
    path = Path(path)
    require(path.is_absolute(), f"not absolute: {path}")
    require(stat.S_ISDIR(path.lstat().st_mode), f"not a real directory: {path}")
    require(path.resolve() == path, f"symlink directory ancestry: {path}")
    return path


def tree_snapshot(root):
    directory(root)
    result = {}
    for path in sorted(root.rglob("*")):
        mode = path.lstat().st_mode
        require(stat.S_ISREG(mode) or stat.S_ISDIR(mode), f"unsupported source type: {path}")
        if stat.S_ISREG(mode):
            result[str(path.relative_to(root))] = {
                "sha256": digest(path), "mtimeNs": path.stat().st_mtime_ns,
                "size": path.stat().st_size,
            }
    return result


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


STORE_ROOT = re.compile(r"/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]+")


def store_path(value, root=False):
    require(isinstance(value, str), "store path must be a string")
    parts = value.split("/")
    require(len(parts) >= 4 and parts[:3] == ["", "nix", "store"]
            and all(p and p not in (".", "..") for p in parts[3:]), "noncanonical store path")
    require(STORE_ROOT.fullmatch("/".join(parts[:4])) is not None,
            "malformed store root")
    require(not root or len(parts) == 4, "identity must be a store root")
    return Path(value)


def resolved_store_path(value):
    path = store_path(value)
    resolved = path.resolve(strict=True)
    # BuildEnv executable links may legitimately point into another store root.
    store_path(str(resolved))
    return resolved


def identity(value):
    require(isinstance(value, dict), "identity must be an object")
    require(value.get("output") == "out", "only the actual out output is supported")
    for key in ("derivationPath", "storePath"):
        store_path(value.get(key), root=True)
    require(value["derivationPath"].endswith(".drv"), "invalid drv path")
    require(not value["storePath"].endswith(".drv"), "output is a derivation path")
    return value


def validate_recipe_bindings(manifest):
    anchors = manifest["recipeAnchors"]
    restoration = manifest["restoration"]
    for entry in restoration["chain"]:
        handle = identity(entry["handle"])
        anchor = anchors.get(handle["derivationPath"])
        require(isinstance(anchor, dict) and anchor.get("handle") == handle,
                "archive recipe anchor identity mismatch")
        require(entry["contextualRecipe"] == anchor.get("contextualRecipe"),
                "archive contextual recipe mismatch")
    require(restoration["chain"][-1]["contextualRecipe"] == manifest["recipes"]["seed"],
            "seed contextual recipe mismatch")
    hook = identity(restoration["hook"])
    anchor = anchors.get(hook["derivationPath"])
    require(isinstance(anchor, dict) and anchor.get("handle") == hook,
            "hook recipe anchor identity mismatch")
    require(restoration["hookRecipe"] == anchor.get("contextualRecipe"),
            "hook contextual recipe mismatch")


def validate_manifest(manifest):
    require(isinstance(manifest, dict) and manifest.get("schemaVersion") == 1,
            "unsupported manifest schema")
    source = directory(manifest["source"])
    expected = fixture.build_files()
    snapshot = tree_snapshot(source)
    require(set(snapshot) == set(expected), "baseline source inventory mismatch")
    for name, content in expected.items():
        require((source / name).read_bytes() == content, f"baseline bytes mismatch: {name}")
    seed = manifest["seed"]
    handle = identity(seed["handle"])
    admission = seed["admission"]
    require(admission["kind"] == "actual-constructor-reconstruction", "admission kind")
    identity(admission["consumer"])
    require(identity(admission["cargoArtifacts"]) == handle, "admitted artifact mismatch")
    require(seed["archive"] == handle["storePath"] + "/target.tar.zst", "seed archive identity")
    require(seed["recipe"]["projectDir"] == "members/app", "seed member mismatch")
    require(manifest["limits"]["exactProducer"] == "not_proven", "producer scope mismatch")
    require(set(manifest["recipes"]) == {"seed", "consumer", "memberLayer", "test", "privateTools"},
            "missing contextual recipes")
    for value in manifest["recipes"].values():
        require(isinstance(value, dict) and value, "empty contextual recipe")
    tools = manifest["tools"]
    private = identity(tools["privateTools"])
    directory(private["storePath"])
    for name in ("cargo", "rustc", "tar", "zstd"):
        path = resolved_store_path(tools[name])
        # Nix tool binaries may be symlinks, but must resolve to regular executables.
        require(path.is_file() and os.access(path, os.X_OK), f"missing executable: {path}")
    for name in ("cargo", "rustc"):
        tool_id = identity(tools["identities"][name])
        require(tools[name] == tool_id["storePath"] + "/bin/" + name, "tool identity mismatch")
    environment = manifest["environment"]
    require(isinstance(environment, dict) and all(isinstance(k, str) and isinstance(v, str)
            for k, v in environment.items()), "environment types")
    require(environment["PATH"] == private["storePath"] + "/bin", "private PATH mismatch")
    require(environment["RUSTC"] == tools["rustc"], "RUSTC mismatch")
    require(not set(environment) & {"CARGO_HOME", "CARGO_TARGET_DIR", "HOME"}, "private env collision")
    restoration = manifest["restoration"]
    require(restoration["kind"] == "tar-zstd-chain-v1", "unsupported restoration")
    hook = identity(restoration["hook"])
    require(isinstance(restoration["hookRecipe"], dict) and restoration["hookRecipe"],
            "missing restoration hook recipe")
    require(hook in manifest["recipes"]["consumer"].get("nativeBuildInputs", []),
            "restoration hook not bound to actual consumer")
    chain = restoration["chain"]
    require(isinstance(chain, list) and 0 < len(chain) <= 64, "archive chain size")
    validate_recipe_bindings(manifest)
    seen = set()
    hashes = {}
    previous = None
    for entry in chain:
        archive = entry["archive"]
        bound = identity(entry["handle"])
        require(archive == bound["storePath"] + "/target.tar.zst", "archive identity mismatch")
        require(archive not in seen, "archive cycle")
        seen.add(archive)
        require(isinstance(entry["contextualRecipe"], dict) and entry["contextualRecipe"],
                "missing archive contextual recipe")
        link = Path(archive + ".prev")
        if previous is None:
            require(not os.path.lexists(link), "unexpected root .prev")
        else:
            require(link.is_symlink() and str(link.resolve(strict=True)) == previous,
                    "archive .prev identity mismatch")
        hashes[archive] = digest(resolved_store_path(archive))
        previous = archive
    require(chain[-1]["handle"] == handle and previous == seed["archive"], "chain seed mismatch")
    require(chain[-1]["recipe"] == seed["recipe"], "chain seed recipe mismatch")
    return source, snapshot, hashes


def parse_messages(text):
    messages = []
    for line in text.splitlines():
        require(bool(line.strip()), "blank Cargo JSON line")
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise Failure(f"malformed Cargo JSON: {error}") from error
        require(isinstance(value, dict) and isinstance(value.get("reason"), str), "Cargo JSON schema")
        if value["reason"] == "compiler-artifact":
            require(type(value.get("fresh")) is bool, "fresh flag is not boolean")
            require(isinstance(value.get("features"), list)
                    and all(isinstance(f, str) for f in value["features"]), "feature schema")
            require(isinstance(value.get("target"), dict), "target schema")
            require("unused-local-probe" not in value["features"], "unused feature activated")
        messages.append(value)
    finished = [m for m in messages if m["reason"] == "build-finished"]
    require(len(finished) == 1 and finished[0].get("success") is True, "missing successful build-finished")
    return messages


def package_matches(message, source, member):
    value = message.get("package_id")
    require(isinstance(value, str), "missing/malformed package_id")
    parsed = urlsplit(value)
    require(parsed.scheme == "path+file" and not parsed.netloc and not parsed.query,
            "unsupported package_id format")
    return (unquote(parsed.path) == str(source / "members" / member)
            and parsed.fragment in ("0.1.0", f"g4-{member}@0.1.0"))


def observe(messages, role, warm=False, rust_edit=False, source=Path("/fixture")):
    artifacts = [m for m in messages if m["reason"] == "compiler-artifact"]
    require(artifacts, f"no compiler artifacts: {role}")
    if warm:
        require(all(m["fresh"] for m in artifacts), f"nonfresh warm artifacts: {role}")
    leaf = [m for m in artifacts if m["target"].get("name") == "g4_leaf"]
    app = [m for m in artifacts if m["target"].get("name") == "g4-app"]
    require(all(package_matches(m, source, "leaf") for m in leaf), "foreign leaf package")
    require(all(package_matches(m, source, "app") for m in app), "foreign app package")
    if role == "peer":
        require(not any(m["reason"] == "build-script-executed" for m in messages)
                and not any(m["target"].get("kind") == ["custom-build"] for m in artifacts),
                "unexpected peer build-script role")
        require(any(m["target"].get("name") == "g4_peer" for m in artifacts), "peer artifact missing")
        if rust_edit:
            require(all(m["fresh"] for m in artifacts), "Rust edit dirtied peer")
    else:
        expected = {frozenset(("build", "macro")),
                    frozenset(("normal", "dev") if role == "test" else ("normal",))}
        require({frozenset(m["features"]) for m in leaf} == expected, f"leaf feature roles: {role}")
        require(len(leaf) == 2, "duplicate/missing leaf role artifacts")
        require(len(app) == 1, "duplicate/missing app artifact")
        require(app[0]["target"].get("kind") == ["bin"]
                and app[0].get("profile", {}).get("test") is (role == "test"),
                "wrong app artifact role")
        if rust_edit:
            require(any(not m["fresh"] for m in leaf) and any(not m["fresh"] for m in app),
                    "fabricated fresh Rust edit: leaf/app must be dirty")
        effects = [m for m in messages if m["reason"] == "build-script-executed"]
        require(len(effects) == 1, "build-script effect missing/duplicate")
        effect = effects[0]
        require(package_matches(effect, source, "app")
                and effect["package_id"] == app[0]["package_id"], "foreign build-script effect package")
        scripts = [m for m in artifacts if m["target"].get("kind") == ["custom-build"]]
        require(len(scripts) == 1 and package_matches(scripts[0], source, "app")
                and scripts[0]["package_id"] == effect["package_id"]
                and scripts[0]["target"].get("src_path") == str(source / "members/app/build.rs"),
                "missing/wrong build-script artifact role")
        require(effect.get("env") == [["G4_BUILD_MARKER", "input-v1:build+macro"]],
                "build-script effect missing/malformed")
    return artifacts


class Runner:
    def __init__(self, logs, environment, lock=None):
        self.logs = logs
        self.environment = environment
        self.lock = lock
        self.number = 0

    def run(self, argv, cwd, cargo=False):
        self.number += 1
        prefix = self.logs / f"{self.number:03d}"
        before = digest(self.lock) if self.lock else None
        record = {"argv": [str(a) for a in argv], "cwd": str(cwd),
                  "environment": self.environment, "lockBefore": before, "cargo": cargo}
        result = None
        try:
            result = subprocess.run(record["argv"], cwd=cwd, env=self.environment,
                                    capture_output=True, check=False)
            prefix.with_suffix(".stdout").write_bytes(result.stdout)
            prefix.with_suffix(".stderr").write_bytes(result.stderr)
            record["exit"] = result.returncode
        except BaseException as error:
            record["exception"] = repr(error)
            raise
        finally:
            try:
                after = digest(self.lock) if self.lock else None
                record["lockAfter"] = after
                record["lockInvariant"] = before == after
            except (OSError, ValueError) as error:
                record["lockError"] = str(error)
                record["lockInvariant"] = False
            write_json(prefix.with_suffix(".json"), record)
        require(record["lockInvariant"], "copied full Cargo.lock changed during command")
        require(result.returncode == 0, f"command failed ({result.returncode}): {record['argv']}")
        return result.stdout.decode("utf-8")


def inspect_tar(path):
    # Crane tar archives preserve regular-file hardlinks. Permit only links to
    # earlier validated regular entries; symlinks/devices remain forbidden.
    with tarfile.open(path, "r:") as archive:
        members = archive.getmembers()
        require(0 < len(members) <= 100000, "archive member count")
        require(sum(m.size for m in members) <= 1024 ** 3, "archive expanded size")
        regular_entries = set()
        destinations = set()
        for member in members:
            name = member.name
            parts = PurePosixPath(name).parts
            require(not name.startswith("/") and ".." not in parts
                    and "secrets" not in parts and ".git" not in parts
                    and not any(p.endswith(".key") for p in parts)
                    and "\\" not in name and all(32 <= ord(c) < 127 for c in name),
                    f"unsafe archive name: {name!r}")
            require(member.isfile() or member.isdir() or member.islnk(),
                    f"unsupported archive entry: {name}")
            canonical = str(PurePosixPath(name))
            require(canonical not in destinations, f"duplicate archive destination: {name}")
            destinations.add(canonical)
            if member.islnk():
                link = member.linkname
                link_parts = PurePosixPath(link).parts
                require(not link.startswith("/") and ".." not in link_parts
                        and "\\" not in link
                        and all(32 <= ord(c) < 127 for c in link)
                        and str(PurePosixPath(link)) in regular_entries,
                        f"unsafe or forward archive hardlink: {name} -> {link}")
                regular_entries.add(canonical)
            elif member.isfile():
                require(parts, f"empty archive regular path: {name}")
                regular_entries.add(canonical)
        return [{"name": m.name, "size": m.size, "type": m.type.decode("ascii"),
                 "linkname": m.linkname if m.islnk() else None}
                for m in members]


def restore(manifest, root, runner):
    target = root / "target"
    target.mkdir()
    for index, entry in enumerate(manifest["restoration"]["chain"]):
        temporary = root / f"restore-{index}.tar"
        # Equivalent to Crane's zstd -> tar extraction, with inspection first.
        runner.run([manifest["tools"]["zstd"], "-d", entry["archive"], "-o", temporary], root)
        listing = inspect_tar(temporary)
        write_json(runner.logs / f"archive-{index}.json", {"binding": entry, "entries": listing})
        runner.run([manifest["tools"]["tar"], "-x", "-f", temporary, "-C", target], root)
        temporary.unlink()


def mutate(root, variant):
    before = tree_snapshot(root)
    baseline = fixture.build_files()
    require(set(before) == set(baseline), "premutation source inventory changed")
    require(all((root / n).read_bytes() == b for n, b in baseline.items()),
            "premutation copied source bytes changed")
    changed = fixture.build_files(variant)
    delta = {}
    for name in baseline:
        if baseline[name] != changed[name]:
            path = root / name
            require(path.read_bytes() == baseline[name], f"unexpected premutation bytes: {name}")
            path.write_bytes(changed[name])
            stamp = time.time_ns()
            require(stamp > before[name]["mtimeNs"], "mutation timestamp must advance")
            os.utime(path, ns=(stamp, stamp))
            delta[name] = {"before": before[name], "afterSha256": digest(path), "mtimeNs": stamp}
    after = tree_snapshot(root)
    require(all(before[n] == after[n] for n in before if n not in delta), "unchanged mtimes/bytes changed")
    return delta


def executable_path(value, target):
    require(isinstance(value, str), "missing executable path")
    path = regular(value)
    require(path.is_absolute() and path.resolve().is_relative_to(target.resolve()), "foreign executable")
    require(os.access(path, os.X_OK), "nonexecutable artifact")
    return path


def phase(manifest, source, runner, name, variant):
    result = {}
    for role, verb, package, extra in (("app", "build", "g4-app", []),
                                      ("peer", "build", "g4-peer", []),
                                      ("test", "test", "g4-app", ["--no-run"])):
        argv = [manifest["tools"]["cargo"], verb, "--release", "--offline", "--locked",
                "--jobs", "1", "-p", package, "--message-format=json"] + extra
        text = runner.run(argv, source, cargo=True)
        messages = parse_messages(text)
        write_json(runner.logs / f"{name}-{role}-messages.json", messages)
        artifacts = observe(messages, role, warm=name in ("warmBaseline", "warmNoOp"),
                            rust_edit=name == "delta" and variant == "rust-edit", source=source)
        result[role] = {"messages": messages}
        if role in ("app", "test"):
            executables = [m.get("executable") for m in artifacts
                           if m["target"].get("name") == "g4-app" and m.get("executable")]
            require(len(executables) == 1, f"expected one {role} executable")
            executable = executable_path(executables[0], Path(runner.environment["CARGO_TARGET_DIR"]))
            output = runner.run([executable] + (["--test-threads=1"] if role == "test" else []), source)
            if role == "app":
                expected_variant = variant if name in ("delta", "warmNoOp") else "baseline"
                require(output == fixture.EXPECTED_STDOUT[expected_variant], "actual app stdout mismatch")
            else:
                require("1 passed" in output and "0 failed" in output, "actual fixture test result missing")
            result[role]["stdout"] = output
    return result


def execute(manifest, output):
    source, original, archives = validate_manifest(manifest)
    tool_hashes = {name: digest(Path(manifest["tools"][name]).resolve(strict=True))
                   for name in ("cargo", "rustc", "tar", "zstd")}
    # Use fixture's confined lexical path rule, then reject symlink ancestry.
    output = fixture._checked_output(output)
    require(not output.is_relative_to(source), "output must not be inside original source")
    directory(output.parent)
    output.mkdir(mode=0o700)  # exclusive; never clean/reuse an existing path
    summary = {"schemaVersion": 1, "status": "failed", "variants": {},
               "exactProducer": "not_proven", "limits": manifest["limits"]}
    write_json(output / "manifest.json", manifest)
    write_json(output / "original-source.json", original)
    write_json(output / "archive-hashes.json", archives)
    write_json(output / "tool-hashes.json", tool_hashes)
    try:
        for variant in fixture.VARIANTS:
            root = output / variant
            root.mkdir()
            copied = root / "source"
            shutil.copytree(source, copied, copy_function=shutil.copy2)
            for path in copied.rglob("*"):
                path.chmod(path.stat().st_mode | stat.S_IWUSR)
            logs = root / "logs"
            logs.mkdir()
            home = root / "home"
            home.mkdir()
            cargo_home = root / "cargo-home"
            cargo_home.mkdir()
            env = {"LANG": "C", "LC_ALL": "C", **manifest["environment"],
                   "HOME": str(home), "CARGO_HOME": str(cargo_home),
                   "CARGO_TARGET_DIR": str(root / "target"), "CARGO_NET_OFFLINE": "true"}
            runner = Runner(logs, env, copied / "Cargo.lock")
            restore(manifest, root, runner)
            observations = {}
            summary["variants"][variant] = observations
            for name in ("prime", "warmBaseline", "delta", "warmNoOp"):
                if name == "delta":
                    write_json(root / "delta.json", mutate(copied, variant))
                observations[name] = phase(manifest, copied, runner, name, variant)
                expected = fixture.build_files(variant if name in ("delta", "warmNoOp") else "baseline")
                copied_snapshot = tree_snapshot(copied)
                require(set(copied_snapshot) == set(expected)
                        and all((copied / n).read_bytes() == b for n, b in expected.items()),
                        "copied source changed outside declared delta")
                write_json(root / f"{name}-source.json", copied_snapshot)
                write_json(output / "summary.json", summary)
        summary["status"] = "passed"
    except BaseException as error:
        summary["error"] = repr(error)
        raise
    finally:
        try:
            require(tree_snapshot(source) == original, "original source changed")
            require({p: digest(resolved_store_path(p)) for p in archives} == archives,
                    "original archive changed")
            for index, entry in enumerate(manifest["restoration"]["chain"]):
                link = Path(entry["archive"] + ".prev")
                if index == 0:
                    require(not os.path.lexists(link), "original root .prev changed")
                else:
                    require(link.is_symlink() and str(link.resolve(strict=True))
                            == manifest["restoration"]["chain"][index - 1]["archive"],
                            "original archive chain changed")
            require({n: digest(Path(manifest["tools"][n]).resolve(strict=True)) for n in tool_hashes}
                    == tool_hashes, "original tool bytes changed")
            summary["immutableOriginals"] = True
        except BaseException as error:
            summary["status"] = "failed"
            summary["immutableOriginals"] = False
            summary["immutableError"] = repr(error)
            raise
        finally:
            write_json(output / "summary.json", summary)
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    try:
        require(Path(args.manifest).is_absolute() and Path(args.output).is_absolute(),
                "manifest/output must be absolute")
        manifest = json.loads(regular(args.manifest).read_text())
        execute(manifest, args.output)
    except (OSError, ValueError, KeyError, TypeError, UnicodeError) as error:
        print(json.dumps({"status": "failed", "error": str(error), "exactProducer": "not_proven"}))
        return 1
    print(json.dumps({"status": "passed", "summary": str(Path(args.output) / "summary.json")}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
