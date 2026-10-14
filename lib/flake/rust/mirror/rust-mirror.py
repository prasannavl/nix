#!/usr/bin/env python3
"""Mirror a resolved Git commit's declared Rust source scope, then validate exports.

The revision-owned v1 support declaration is dependency authority, not an
arbitrary-Nix closure certificate. Validation exercises native exports only;
dormant functions, external caller arguments and build-time reads are unproven.
No worktree overlays, fetchers, network operations, Cargo or native builds.
"""

import argparse
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib

ENTRY = "lib/flake/rust/mirror.nix"
PLANNER = "lib/flake/rust/closures.nix"
CONTRACT = "lib/flake/rust/mirror-sources.nix"
STAMP = ".rust-mirror.json"
INPUTS = ("nixpkgs", "crane", "flake-utils")
ROOT_METADATA = ("Cargo.toml", "Cargo.lock", ".gitignore", "treefmt.toml")
# Bounds on already obtained immutable tree metadata, not a payload scanner.
MAX_TREE_BYTES = 16 * 1024 * 1024
MAX_TREE_ENTRIES = 100000


def require(test, message):
    if not test:
        raise ValueError(message)


def safe_path(path):
    require(isinstance(path, str) and path and
            not any(ord(c) < 32 or ord(c) == 127 for c in path), f"unsafe path: {path!r}")
    require(not any(p in ("", ".", "..", ".git") for p in path.split("/")) and
            not any(c in path for c in "\\:*?[]${}"), f"unsafe path: {path!r}")
    require(not (path == "data" or path == "data/secrets" or path.startswith("data/secrets/")),
            f"forbidden secrets path: {path}")
    reject_secret_location(path)
    return path


def reject_secret_location(path):
    parts = Path(path).parts
    require(not any(parts[i:i + 2] == ("data", "secrets") for i in range(len(parts) - 1)),
            f"forbidden secrets location: {path}")


def run(argv, cwd=None, data=None):
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_NO_REPLACE_OBJECTS="1", GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0",
               GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null", NIX_PATH="")
    result = subprocess.run(argv, cwd=cwd, input=data, capture_output=True, timeout=60, env=env)
    require(result.returncode == 0,
            f"{argv[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_json(data):
    return json.loads(data, object_pairs_hook=unique_object)


class Objects:
    def __init__(self, repo, rev):
        reject_secret_location(Path(os.path.abspath(repo)))
        self.repo = Path(repo).resolve(strict=True)
        reject_secret_location(self.repo)
        require(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", rev) is not None,
                "--rev must be a full resolved commit object ID")
        bare = self.git("rev-parse", "--is-bare-repository").strip() == b"true"
        self.git_dir = Path(os.fsdecode(self.git(
            "rev-parse", "--path-format=absolute", "--git-common-dir").strip())).resolve(strict=True)
        self.repo = self.git_dir if bare else Path(os.fsdecode(
            self.git("rev-parse", "--show-toplevel").strip())).resolve(strict=True)
        reject_secret_location(self.repo)
        reject_secret_location(self.git_dir)
        self.rev = rev
        require(self.git("cat-file", "-t", rev).strip() == b"commit", "revision is not a commit")
        self.entries, self.trees, self.files = {}, {}, {}
        # Include exact directory tree IDs; files remain in the existing cache.
        # No archive, worktree scan, link text or payload reads are introduced.
        data = self.git("ls-tree", "-rtz", "--full-tree", rev)
        require(len(data) <= MAX_TREE_BYTES and (not data or data.endswith(b"\0")),
                "invalid/oversized pinned tree metadata")
        records = data.split(b"\0")[:-1] if data else []
        require(len(records) <= MAX_TREE_ENTRIES, "too many pinned tree entries")
        for record in records:
            require(record.count(b"\t") == 1, "invalid pinned tree record")
            header, path = record.split(b"\t", 1)
            fields = header.decode("ascii").split(" ")
            require(len(fields) == 3, "invalid pinned tree header")
            mode, kind, oid = fields
            require(re.fullmatch(r"[0-9a-f]{%d}" % len(rev), oid) is not None,
                    "invalid pinned tree object ID")
            require((mode, kind) in (("040000", "tree"), ("100644", "blob"),
                                    ("100755", "blob"), ("120000", "blob"),
                                    ("160000", "commit")), "unknown pinned tree mode/type")
            path = path.decode("utf-8")
            require(path and len(path) <= 4096, "invalid pinned tree path length")
            require(path not in self.entries and path not in self.trees,
                    "duplicate/aliased pinned tree path")
            (self.trees if kind == "tree" else self.entries)[path] = (mode, kind, oid)

    def git(self, *args):
        return run(["git", "--no-replace-objects", "-C", str(self.repo), *args])

    def preflight(self, paths, tree_paths=()):
        # Finite exact Git metadata inventory, before selected payload reads.
        paths, tree_paths = sorted(set(paths)), set(tree_paths)
        require(len(paths) + len(tree_paths) <= MAX_TREE_ENTRIES,
                "too many scoped source entries")
        for path in paths + sorted(tree_paths):
            safe_path(path)
            parents = [str(p) for p in PurePosixPath(path).parents if str(p) != "."]
            require(len(parents) <= 128, "scoped source path too deep")
            require(not any(p in self.entries for p in parents), "source path aliases a file")
            tree_paths.update(parents)
        require(len(paths) + len(tree_paths) <= MAX_TREE_ENTRIES,
                "too many scoped source entries")
        for path in paths:
            require(path in self.entries, f"missing pinned source: {path}")
            mode, kind, oid = self.entries[path]
            require(mode in ("100644", "100755") and kind == "blob",
                    f"unsafe source mode: {path}: {mode}")
            require(re.fullmatch(r"[0-9a-f]{%d}" % len(self.rev), oid) is not None,
                    "invalid scoped blob object ID")
        for path in sorted(tree_paths):
            require(path in self.trees and path not in self.entries,
                    f"missing/aliased pinned directory: {path}")
            mode, kind, oid = self.trees[path]
            require((mode, kind) == ("040000", "tree") and
                    re.fullmatch(r"[0-9a-f]{%d}" % len(self.rev), oid) is not None,
                    "invalid scoped directory tree")
        def records(names, entries):
            return [{"path": path, "mode": entries[path][0],
                     "type": entries[path][1], "objectId": entries[path][2]}
                    for path in sorted(names)]
        return {"revision": self.rev, "files": records(paths, self.entries),
                "trees": records(tree_paths, self.trees)}

    def read(self, path):
        self.preflight([path])
        if path not in self.files:
            mode, _, oid = self.entries[path]
            self.files[path] = (self.git("cat-file", "blob", oid), int(mode[-3:], 8))
        return self.files[path][0]

    def paths(self, root):
        safe_path(root)
        paths = sorted(p for p in self.entries if p == root or p.startswith(root + "/"))
        require(paths, f"missing pinned support/member source: {root}")
        return paths


def materialize(root, files):
    for path, (data, mode) in files.items():
        safe_path(path)
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(mode)


def nix_string(value):
    return json.dumps(value, ensure_ascii=False).replace("${", "\\${")


def nix_list(values):
    return "[ " + " ".join(nix_string(safe_path(value)) for value in values) + " ]"


def evaluate(code, allowed, scratch):
    # Evaluator code gets its own narrow root, never the planning parent.
    area = Path(tempfile.mkdtemp(prefix="evaluation-", dir=scratch))
    expression = area / "default.nix"
    expression.write_text(code)
    argv = ["nix", "eval", "--offline", "--restrict-eval", "--option", "allowed-uris", "",
            "--option", "allow-import-from-derivation", "false", "--json", "--file", str(expression)]
    for index, path in enumerate([area, *allowed]):
        argv.extend(["-I", f"mirror-allowed-{index}={path}"])
    return parse_json(run(argv, cwd=area))


def source_contract(objects, scratch):
    # Evaluate only the immutable declaration blob. No support/helper imports or
    # working-tree bytes are available in this isolated metadata namespace.
    area = Path(tempfile.mkdtemp(prefix="declaration-", dir=scratch))
    declaration = area / "sources.nix"
    declaration.write_bytes(objects.read(CONTRACT))
    result = evaluate(f"import {nix_string(str(declaration))}\n", [area], scratch)
    require(isinstance(result, dict) and {"version", "supportSources"} <= set(result) and
            set(result) <= {"version", "supportSources", "excludeSupportSources"} and
            type(result["version"]) is int and result["version"] == 1,
            "unsupported source contract: require version 1 and supportSources")
    roots = result["supportSources"]
    require(isinstance(roots, list) and roots and len(set(map(str, roots))) == len(roots),
            "source contract requires nonempty unique supportSources")
    for root in roots:
        safe_path(root)
    require(not any(a != b and b.startswith(a + "/") for a in roots for b in roots),
            "overlapping support sources")
    excluded = result.setdefault("excludeSupportSources", [])
    require(isinstance(excluded, list) and len(set(map(str, excluded))) == len(excluded),
            "source contract requires unique excludeSupportSources")
    for path in excluded:
        safe_path(path)
        require(any(path.startswith(root + "/") for root in roots),
                "support exclusion must be a strict descendant of a support source")
        require(path not in ROOT_METADATA, "support exclusion cannot remove root metadata")
    require(not any(a != b and b.startswith(a + "/") for a in excluded for b in excluded),
            "overlapping support exclusions")
    require(all(support_path(p, result) for p in (CONTRACT, ENTRY, PLANNER)),
            "source contract omits exporter/planner ownership")
    return result


def support_path(path, contract):
    def within(root):
        return path == root or path.startswith(root + "/")
    return (any(within(root) for root in contract["supportSources"]) and
            not any(within(root) for root in contract["excludeSupportSources"]))


def nix_plan(snapshot, member_dirs=None):
    scope = "" if member_dirs is None else f" memberDirs = {nix_list(member_dirs)};"
    code = (f"let src = /. + {nix_string(str(snapshot))}; in "
            f'(import (src + "/{PLANNER}")).plan {{ inherit src;{scope} }}\n')
    return evaluate(code, [snapshot], snapshot.parent)


def prune_lock(lock):
    require(lock["version"] == 7, "unsupported lock version")
    nodes, root = lock["nodes"], lock["root"]
    selected = {name: nodes[root]["inputs"][name] for name in INPUTS}
    kept, active = {}, set()

    def resolve(edge, chain=()):
        if isinstance(edge, str):
            require(edge in nodes and edge != root, "invalid lock node edge")
            return edge
        require(isinstance(edge, list) and all(isinstance(p, str) for p in edge), "invalid follows")
        key = tuple(edge)
        require(key not in chain and edge, "cyclic/empty follows")
        node = root
        for name in edge:
            node = resolve(nodes[node]["inputs"][name], chain + (key,))
        return node

    def visit(node):
        require(node not in active, "cyclic lock graph")
        if node in kept:
            return
        active.add(node)
        original = nodes[node]
        locked = original["locked"]
        require(locked.get("type") == "github" and
                re.fullmatch(r"[0-9a-f]{40}", locked.get("rev", "")) and
                isinstance(locked.get("narHash"), str) and locked["narHash"],
                "require immutable GitHub lock nodes")
        edges = {name: resolve(edge) for name, edge in original.get("inputs", {}).items()}
        for child in edges.values():
            visit(child)
        kept[node] = dict(original, inputs=edges)
        active.remove(node)

    selected = {name: resolve(edge) for name, edge in selected.items()}
    for node in selected.values():
        visit(node)
    kept[root] = {"inputs": selected}
    return {"version": 7, "root": root, "nodes": kept}


def render_export(spec, lock):
    urls = []
    for name in INPUTS:
        node = lock["nodes"][lock["nodes"][lock["root"]]["inputs"][name]]
        original, locked = node["original"], node["locked"]
        require(original.get("type") == "github" and
                set(original) <= {"type", "owner", "repo", "ref", "rev"}, "unsupported original input")
        for field in ("owner", "repo"):
            require(re.fullmatch(r"[A-Za-z0-9_.-]+", original.get(field, "")) is not None and
                    original[field] == locked.get(field), "input source provenance mismatch")
        require(not ("ref" in original and "rev" in original), "ambiguous original ref/rev")
        suffix = original.get("ref", original.get("rev"))
        if "rev" in original:
            require(original["rev"] == locked["rev"], "original/locked revision mismatch")
        if suffix is not None:
            require(re.fullmatch(r"[A-Za-z0-9_.+/-]+", suffix) is not None, "unsafe original ref")
        url = f"github:{original['owner']}/{original['repo']}" + (f"/{suffix}" if suffix else "")
        urls.append(f"    {name}.url = {nix_string(url)};")
    flake = ("{\n  inputs = {\n" + "\n".join(urls) + "\n  };\n"
             "  outputs = inputs: (import ./lib/flake/rust/mirror.nix) {\n"
             "    inherit inputs;\n    src = ./.;\n"
             f"    memberDirs = {nix_list(spec['memberDirs'])};\n"
             f"    primaryMember = {nix_string(safe_path(spec['primaryMember']))};\n"
             "  };\n}\n")
    return {"flake.nix": (flake.encode(), 0o644),
            "flake.lock": ((json.dumps(lock, sort_keys=True, indent=2) + "\n").encode(), 0o644)}


def cached_inputs(lock):
    paths = {}
    for name, node in lock["nodes"].items():
        if name == lock["root"]:
            continue
        digest = node["locked"]["narHash"]
        require(digest.startswith("sha256-"), "locked input requires SHA256 SRI narHash")
        raw = base64.b64decode(digest[7:], validate=True)
        require(len(raw) == 32, "invalid locked input narHash")
        # Pure path calculation and local validity query. Never invoke fetchTree,
        # getFlake, flake metadata, substituters or any network-capable fetcher.
        path = Path(os.fsdecode(run(["nix-store", "--store", "daemon", "--print-fixed-path",
                                     "--recursive", "sha256", raw.hex(), "source"]).strip()))
        try:
            info = parse_json(run(["nix", "path-info", "--store", "daemon", "--offline", "--json", str(path)]))
        except ValueError as error:
            raise ValueError(f"uncached locked input {name}: {path}; populate cache separately") from error
        record = (info[0] if info else None) if isinstance(info, list) else info.get(str(path))
        require(isinstance(record, dict),
                f"uncached locked input {name}: {path}; populate cache separately")
        require(record["narHash"] == digest, f"cached input hash mismatch: {name}")
        paths[name] = str(path)
    return paths


def validate_export(snapshot, lock):
    paths = cached_inputs(lock)
    dependencies = set(paths.values())
    for path in paths.values():
        dependencies.update(os.fsdecode(run([
            "nix-store", "--store", "daemon", "--query", "--requisites", path])).splitlines())
    validator = Path(__file__).with_name("rust-mirror-validate.nix").read_text()
    code = ("let validate = (" + validator + "); in validate { "
            f"src = /. + {nix_string(str(snapshot))}; "
            f"lock = builtins.fromJSON {nix_string(json.dumps(lock))}; "
            f"sources = builtins.fromJSON {nix_string(json.dumps(paths))}; }}\n")
    result = evaluate(code, [snapshot, *sorted(dependencies)], snapshot.parent)
    require(isinstance(result, dict) and result.get("validated") is True,
            "native export validation did not return evidence")
    return result


def generate(objects, scratch, member, _planner=nix_plan, _renderer=render_export,
             _validator=validate_export):
    safe_path(member)
    require("Cargo.lock.nix" not in objects.entries and "Cargo.lock.nix" not in objects.trees,
            "unsupported-cargo-lock-policy: Cargo.lock.nix")
    contract = source_contract(objects, scratch.parent)
    workspace = tomllib.loads(objects.read("Cargo.toml").decode("utf-8"))
    dirs = workspace["workspace"]["members"]
    require(isinstance(dirs, list) and dirs and len(set(map(str, dirs))) == len(dirs),
            "explicit unique workspace members required")
    for directory in dirs:
        safe_path(directory)
    # V1 planning namespace: all member-directory metadata and pinned Cargo.toml
    # blobs (including nested manifests), root metadata and the pinned planner.
    # Nonmanifest payloads are absent, not fabricated. Revisions opt into this
    # snapshot interface via the mandatory v1 declaration; read failures reject.
    for path in objects.entries:
        parts = path.split("/")
        if ".cargo" in parts:
            parent = "/".join(parts[:parts.index(".cargo")])
            require(parent and not any(parent == d or parent.startswith(d + "/") or
                                       d.startswith(parent + "/") for d in dirs),
                    f"unsupported local-cargo-config: {path}")
    members = {d: objects.paths(d) for d in dirs}
    # Ownership exclusions apply only here, never to member metadata/payloads.
    support = {r: [p for p in objects.paths(r) if support_path(p, contract)]
               for r in contract["supportSources"]}
    member_paths = {p for paths in members.values() for p in paths}
    all_paths = set(ROOT_METADATA) | {PLANNER, ENTRY, CONTRACT, "flake.lock"} | member_paths
    all_paths.update(p for paths in support.values() for p in paths)
    require(STAMP not in objects.entries, "reserved provenance stamp collides with pinned source")
    owned_trees = {p for p in objects.trees if support_path(p, contract) or
                   any(p == d or p.startswith(d + "/") for d in dirs)}
    objects.preflight(all_paths, owned_trees)  # Before selected payload reads.
    require(all(d not in objects.entries for d in dirs), "member must be a source directory")
    for p in sorted(all_paths):
        if p in ROOT_METADATA or p in (PLANNER, "flake.lock") or (
                p in member_paths and PurePosixPath(p).name == "Cargo.toml"):
            objects.read(p)
    for paths in members.values():
        for p in paths:
            (scratch / PurePosixPath(p).parent).mkdir(parents=True, exist_ok=True)
    materialize(scratch, objects.files)
    planned = _planner(scratch)
    require(planned["supported"] is True, f"unsupported planner source: {planned['reasons']}")
    components = [c for c in planned["plan"]["components"] if member in c]
    require(len(components) == 1, "--member must name a declared member directory")
    component = sorted(components[0])
    require(component and len(set(component)) == len(component) and set(component) <= set(dirs),
            "planner returned invalid members")
    for directory in component:
        require(directory + "/default.nix" in objects.entries,
                f"missing pinned member definition: {directory}/default.nix")
    selected = set(ROOT_METADATA) | {p for d in component for p in members[d]}
    selected.update(p for paths in support.values() for p in paths)
    require(not selected & {STAMP, "flake.nix", "flake.lock"},
            "reserved generated file collides with pinned source")
    selected_trees = {p for p in owned_trees if support_path(p, contract) or
                      any(p == d or p.startswith(d + "/") for d in component)}
    # Original pinned flake.lock provenance is distinct from the pruned output.
    source_inventory = objects.preflight(selected | {"flake.lock"}, selected_trees)
    files = {}
    for p in sorted(selected):
        objects.read(p)
        files[p] = objects.files[p]
    lock = prune_lock(parse_json(objects.read("flake.lock")))
    spec = {"memberDirs": component, "primaryMember": member}
    generated = _renderer(spec, lock)
    require(set(generated) == {"flake.nix", "flake.lock"}, "exporter must emit only root flake/lock")
    files.update(generated)
    for path, (data, mode) in files.items():
        safe_path(path)
        require(isinstance(data, bytes) and mode in (0o644, 0o755), "invalid generated file/mode")
    validation = Path(tempfile.mkdtemp(prefix="mirror-validation-", dir=scratch.parent))
    materialize(validation, files)
    scoped = _planner(validation, component)
    require(scoped["supported"] is True, f"unsupported scoped mirror: {scoped['reasons']}")
    _validator(validation, lock)  # Mandatory in production, no CLI bypass.
    inventory = {p: {"sha256": hashlib.sha256(data).hexdigest(), "mode": mode}
                 for p, (data, mode) in sorted(files.items())}
    stamp = {"generator": "rust-mirror-v1", "revision": objects.rev, "selection": spec,
             "sourceContract": contract, "pinnedSourceInventory": source_inventory,
             "files": inventory}
    files[STAMP] = ((json.dumps(stamp, sort_keys=True, indent=2) + "\n").encode(), 0o644)
    return files


def inspect_output(output, owned=False):
    reject_secret_location(output)
    files, directories = {}, set()
    require(output.is_dir() and not output.is_symlink(), "unsafe output directory")
    if owned:
        marker = output / STAMP
        require(not marker.is_symlink() and marker.is_file() and marker.stat().st_nlink == 1,
                "refusing non-generator-owned output")
        stamp = parse_json(marker.read_bytes())
        require(isinstance(stamp, dict) and stamp.get("generator") == "rust-mirror-v1",
                "unknown output owner")
    for directory, dirs, names in os.walk(output, followlinks=False):
        for name in dirs + names:
            path = Path(directory) / name
            rel = safe_path(path.relative_to(output).as_posix())
            info = path.lstat()
            require(not stat.S_ISLNK(info.st_mode), f"output symlink: {rel}")
            if stat.S_ISDIR(info.st_mode):
                directories.add(rel)
            else:
                require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, f"unsafe output file: {rel}")
                files[rel] = (path.read_bytes(), stat.S_IMODE(info.st_mode))
    expected = {str(parent) for p in files for parent in PurePosixPath(p).parents if str(parent) != "."}
    require(directories == expected, "extra output directories")
    return files


def output_path(output, objects):
    output = Path(os.path.abspath(output))
    reject_secret_location(output)
    require(not any(ord(c) < 32 or ord(c) == 127 for c in str(output)), "unsafe output path")
    for path in (output, *output.parents):
        require(not path.is_symlink() and path.name != ".git", f"unsafe output ancestor: {path}")
    require(output != Path.home() and output != Path("/"), "unsafe output root")
    for source in (objects.repo, objects.git_dir):
        require(not output.is_relative_to(source) and not source.is_relative_to(output),
                "output aliases/contains/is inside source repository")
    require(output.parent.is_dir(), "output parent must already exist")
    return output


def publish(output, files, scratch, check=False):
    reject_secret_location(output)
    # Concurrent hostile namespace mutation is not supported.
    for path in (output, *output.parents):
        require(not path.is_symlink() and path.name != ".git", f"unsafe output ancestor: {path}")
    existing = inspect_output(output, owned=True) if output.exists() else None
    if check:
        require(existing == files, "mirror stale: missing, extra, changed files/modes/provenance")
        return
    if existing is not None:
        stamp = parse_json(existing[STAMP][0])
        actual = {p: {"sha256": hashlib.sha256(data).hexdigest(), "mode": mode}
                  for p, (data, mode) in existing.items() if p != STAMP}
        require(stamp["files"] == actual, "refusing modified/extra generator output")
    stage = scratch / "output"
    stage.mkdir()
    materialize(stage, files)
    require(stage.stat().st_dev == output.parent.stat().st_dev, "atomic output needs same filesystem")
    libc = ctypes.CDLL(None, use_errno=True)
    require(hasattr(libc, "renameat2"), "atomic output requires Linux renameat2")
    flag = 1 if existing is None else 2  # NOREPLACE / EXCHANGE
    result = libc.renameat2(-100, os.fsencode(stage), -100, os.fsencode(output), flag)
    require(result == 0, f"atomic rename failed: errno {ctypes.get_errno()}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="source Git repository (not an overlay)")
    parser.add_argument("--rev", required=True, help="full resolved commit object ID, never a ref")
    parser.add_argument("--member", required=True, help="declared member directory, not package name")
    parser.add_argument("--output", required=True, help="separate output; existing parent required")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true", help="read-only output freshness check")
    args = parser.parse_args(argv)
    scratch = None
    try:
        # Reject both lexical secret-tree locations before any Git/ownership
        # inspection, even when the destination is outside the source repo.
        reject_secret_location(Path(os.path.abspath(args.repo)))
        reject_secret_location(Path(os.path.abspath(args.output)))
        objects = Objects(args.repo, args.rev)
        output = output_path(args.output, objects)
        tmp = objects.repo / "tmp"
        require(not tmp.is_symlink(), "repository tmp must not be a symlink")
        tmp.mkdir(exist_ok=True)
        require(tmp.is_dir(), "repository tmp must be a regular directory")
        scratch = Path(tempfile.mkdtemp(prefix="rust-mirror-", dir=tmp))
        snapshot = scratch / "source"
        snapshot.mkdir()
        files = generate(objects, snapshot, args.member)
        publish(output, files, scratch, check=args.check)
        shutil.rmtree(scratch)
        print("mirror matches" if args.check else "mirror written")
        return 0
    except (ValueError, OSError, KeyError, TypeError, UnicodeError, RecursionError,
            subprocess.TimeoutExpired) as error:
        print(f"rust-mirror: {error}", file=sys.stderr)
        if scratch is not None:
            print(f"retained diagnostic snapshot: {scratch}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
