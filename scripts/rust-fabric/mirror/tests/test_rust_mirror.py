"""Immutable object fixtures, declared source scopes and bounded export validation.

All temporary state stays in tmp/fresh-review-generator. Cached integration
uses only declared support areas and tiny Rust fixtures; never production Git
metadata, secrets, Cargo/native builds, fetchers, refs or index operations.
"""

import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[4]
PRIVATE = ROOT / "tmp/fresh-review-generator"
SPEC = importlib.util.spec_from_file_location("rust_mirror", ROOT / "scripts/rust-fabric/mirror/rust-mirror.py")
mirror = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mirror)


def lock_fixture():
    nodes = {"root": {"inputs": {name: name for name in mirror.INPUTS}}}
    for name in (*mirror.INPUTS, "systems", "unrelated"):
        source = {"type": "github", "owner": "fixture", "repo": name}
        digest = "sha256-" + base64.b64encode(hashlib.sha256(name.encode()).digest()).decode()
        nodes[name] = {"original": source, "locked": dict(source, rev="1" * 40, narHash=digest)}
    nodes["root"]["inputs"]["unrelated"] = "unrelated"
    nodes["flake-utils"]["inputs"] = {"systems": "systems", "nixpkgs": ["nixpkgs"]}
    return {"version": 7, "root": "root", "nodes": nodes}


def sources():
    return {
        "Cargo.toml": b'[workspace]\nresolver = "2"\nmembers = ["pkgs/a", "pkgs/b", "pkgs/unrelated"]\n',
        "Cargo.lock": b"# original lock\n",
        ".gitignore": b"target\n",
        "treefmt.toml": b"# original formatter\n",
        "flake.lock": json.dumps(lock_fixture()).encode(),
        mirror.CONTRACT: (b'{ version = 1; supportSources = [ "lib/flake" "lib/services" ]; '
                          b'excludeSupportSources = [ "lib/flake/tests" ]; }'),
        mirror.ENTRY: b"{ ... }: {}\n",
        mirror.PLANNER: b"{}\n",
        "lib/flake/helper.nix": b"{}\n",
        "lib/flake/pkg-helper.sh": (b"#!/bin/sh\nprintf fixture\n", "100755"),
        "lib/flake/resources/payload.json": b'"fixture-payload"',
        "lib/flake/tests/fixture.txt": b"excluded test-owned resource",
        "lib/flake/tests/source-link": (b"../resources", "120000"),
        "lib/services/module.nix": b"{}\n",
        "lib/ext/not-owned.nix": b"must not be read",
        "pkgs/a/Cargo.toml": b'[package]\nname = "a"\nversion = "0.1.0"\n',
        "pkgs/a/default.nix": b"{}\n",
        "pkgs/a/flake.nix": b"import ../../lib/flake/helper.nix\n",
        "pkgs/a/src/main.rs": b"fn main() {}\n",
        "pkgs/a/tool": (b"binary\0bytes\xff", "100755"),
        "pkgs/b/Cargo.toml": b'[package]\nname = "b"\nversion = "0.1.0"\n',
        "pkgs/b/default.nix": b"{}\n",
        "pkgs/b/src/lib.rs": b"// b\n",
        "pkgs/unrelated/Cargo.toml": b'[package]\nname = "unrelated"\nversion = "0.1.0"\n',
        "pkgs/unrelated/nested/Cargo.toml": b'[package]\nname = "nested"\nversion = "0.1.0"\n',
        "pkgs/unrelated/src/lib.rs": b"unselected regular payload",
        "data/secrets/synthetic.key": b"synthetic forbidden bytes, never read",
    }


class Fixture:
    def __init__(self, directory, files, bare=True, reuse=None):
        self.repo = reuse.repo if reuse else directory / "repo"
        self.cache = reuse.cache if reuse else {}
        if not reuse:
            subprocess.run(["git", "init", "--quiet", *(["--bare"] if bare else []), str(self.repo)],
                           check=True, timeout=10)
        self.source_files = files
        tree = {}
        for path, value in files.items():
            data, mode = value if isinstance(value, tuple) else (value, "100644")
            kind = "commit" if mode == "160000" else "blob"
            if kind == "commit":
                empty = self.git("mktree", data=b"").strip().decode()
                data = (f"tree {empty}\nauthor Fixture <fixture@invalid> 1 +0000\n"
                        "committer Fixture <fixture@invalid> 1 +0000\n\n").encode() + data
            key = (kind, data)
            if key not in self.cache:
                self.cache[key] = self.git("hash-object", "-w", "-t", kind, "--stdin", data=data).strip().decode()
            parent = tree
            *parts, name = path.split("/")
            for part in parts:
                parent = parent.setdefault(part, {})
            parent[name] = (mode, kind, self.cache[key])

        def write_tree(entries):
            records = []
            for name, entry in sorted(entries.items()):
                mode, kind, oid = ("040000", "tree", write_tree(entry)) if isinstance(entry, dict) else entry
                records.append(f"{mode} {kind} {oid}\t{name}".encode() + b"\0")
            data = b"".join(records)
            key = ("tree", data)
            if key not in self.cache:
                self.cache[key] = self.git("mktree", "-z", "--missing", data=data).strip().decode()
            return self.cache[key]

        oid = write_tree(tree)
        data = (f"tree {oid}\nauthor Fixture <fixture@invalid> 1 +0000\n"
                "committer Fixture <fixture@invalid> 1 +0000\n\nsynthetic\n").encode()
        self.rev = self.git("hash-object", "-w", "-t", "commit", "--stdin", data=data).strip().decode()

    def git(self, *args, data=None):
        return mirror.run(["git", "--no-replace-objects", "-C", str(self.repo), *args], data=data)

    def objects(self):
        return mirror.Objects(self.repo, self.rev)

    def revise(self, changes):
        files = dict(self.source_files)
        for path, value in changes.items():
            if value is None:
                files.pop(path, None)
            else:
                files[path] = value
        return Fixture(self.repo.parent, files, reuse=self)


def fake_plan(snapshot, member_dirs=None):
    assert (snapshot / "Cargo.toml").read_bytes() == sources()["Cargo.toml"]
    if member_dirs is None:
        assert (snapshot / "pkgs/unrelated/Cargo.toml").is_file()
        assert (snapshot / "pkgs/unrelated/nested/Cargo.toml").is_file()
        assert not (snapshot / "pkgs/unrelated/src/lib.rs").exists()
        components = [["pkgs/a", "pkgs/b"], ["pkgs/unrelated"]]
    else:
        assert member_dirs == ["pkgs/a", "pkgs/b"]
        assert not (snapshot / "pkgs/unrelated").exists()
        components = [member_dirs]
    return {"supported": True, "reasons": [], "plan": {"components": components}}


class MetadataRAMTests(unittest.TestCase):
    """Immutable metadata regressions with no Git or filesystem fixtures."""

    def query_tree(self, data, rev):
        def query(*args):
            if args == ("rev-parse", "--is-bare-repository"):
                return b"true\n"
            if args == ("rev-parse", "--path-format=absolute", "--git-common-dir"):
                return b"/rust-mirror-ram/repo\n"
            if args == ("cat-file", "-t", rev):
                return b"commit\n"
            if args == ("ls-tree", "-rtz", "--full-tree", rev):
                return data
            self.fail("unexpected Git/blob request in RAM metadata test")
        return Mock(side_effect=query)

    def construct(self, data, rev, query):
        with patch.object(Path, "resolve", lambda path, **kwargs: path), \
                patch.object(mirror, "reject_secret_location"), \
                patch.object(mirror.Objects, "git", query):
            objects = mirror.Objects("/rust-mirror-ram/repo", rev)
        objects.git = query
        return objects

    def records(self, rows):
        return b"".join(f"{mode} {kind} {oid}\t{path}".encode() + b"\0"
                        for mode, kind, oid, path in rows)

    def assert_no_blobs(self, query):
        self.assertFalse(any(call.args[:2] == ("cat-file", "blob")
                             for call in query.call_args_list))

    def memory_objects(self, width=40, files=None):
        # Opaque full-width test IDs are not an actual Git ownership receipt.
        files = sources() if files is None else files
        objects = mirror.Objects.__new__(mirror.Objects)
        objects.rev = "c" * width
        objects.entries, objects.trees, objects.files = {}, {}, {}
        blobs = {}
        for index, (path, value) in enumerate(sorted(files.items()), 1):
            data, mode = value if isinstance(value, tuple) else (value, "100644")
            oid = format(index, f"0{width}x")
            objects.entries[path] = (mode, "commit" if mode == "160000" else "blob", oid)
            blobs[oid] = data
            for parent in Path(path).parents:
                if str(parent) != ".":
                    objects.trees[str(parent)] = ("040000", "tree", "d" * width)
        def blob(*args):
            self.assertEqual(args[:2], ("cat-file", "blob"))
            self.assertIn(args[2], blobs)
            return blobs[args[2]]
        objects.git = Mock(side_effect=blob)
        return objects

    def test_duplicate_records_refuse_before_blob_read(self):
        for width in (40, 64):
            for mode, kind in (("040000", "tree"), ("100644", "blob")):
                with self.subTest(width=width, kind=kind):
                    rev = "c" * width
                    data = self.records([(mode, kind, "a" * width, "lib"),
                                         (mode, kind, "b" * width, "lib")])
                    query = self.query_tree(data, rev)
                    with self.assertRaisesRegex(ValueError, "duplicate/aliased"):
                        self.construct(data, rev, query)
                    self.assert_no_blobs(query)

    def test_invalid_object_ids_refuse_before_blob_read(self):
        for width in (40, 64):
            for oid in ("bad", "A" * width, "a" * (64 if width == 40 else 40)):
                with self.subTest(width=width, oidLength=len(oid)):
                    rev = "c" * width
                    data = self.records([("100644", "blob", oid, ".gitignore")])
                    query = self.query_tree(data, rev)
                    with self.assertRaisesRegex(ValueError, "object ID"):
                        self.construct(data, rev, query)
                    self.assert_no_blobs(query)

    def test_file_tree_collision_and_unknown_modes_refuse(self):
        rev = "c" * 40
        for rows in (
                [("040000", "tree", "a" * 40, "lib"),
                 ("100644", "blob", "b" * 40, "lib")],
                [("100600", "blob", "a" * 40, "lib")],
                [("100644", "unknown", "a" * 40, "lib")],
                [("040000", "blob", "a" * 40, "lib")]):
            with self.subTest(rows=rows):
                data = self.records(rows)
                query = self.query_tree(data, rev)
                with self.assertRaises(ValueError):
                    self.construct(data, rev, query)
                self.assert_no_blobs(query)

    def test_malformed_and_bounded_metadata_refuse(self):
        rev = "c" * 40
        valid = self.records([("100644", "blob", "a" * 40, "Cargo.lock")])
        for data in (b"bad\0", valid[:-1], valid.replace(b" blob ", b"  blob "),
                     valid.replace(b"Cargo.lock", b"bad\tname")):
            with self.subTest(data=data):
                query = self.query_tree(data, rev)
                with self.assertRaises(ValueError):
                    self.construct(data, rev, query)
                self.assert_no_blobs(query)
        for name, limit in (("MAX_TREE_BYTES", 1), ("MAX_TREE_ENTRIES", 0)):
            with self.subTest(bound=name):
                query = self.query_tree(valid, rev)
                with patch.object(mirror, name, limit), self.assertRaises(ValueError):
                    self.construct(valid, rev, query)
                self.assert_no_blobs(query)

    def test_nonimmutable_revision_refuses_before_git(self):
        for rev in ("HEAD", "c" * 12, "c" * 40 + "^{commit}"):
            with self.subTest(rev=rev):
                query = self.query_tree(b"", rev)
                with self.assertRaises(ValueError):
                    self.construct(b"", rev, query)
                query.assert_not_called()

    def test_valid_tree_ingestion_keeps_separate_caches(self):
        for width in (40, 64):
            with self.subTest(width=width):
                rev = "c" * width
                data = self.records([("100755", "blob", "a" * width, "lib/services/tool"),
                                     ("040000", "tree", "d" * width, "lib/services"),
                                     ("040000", "tree", "e" * width, "lib")])
                query = self.query_tree(data, rev)
                objects = self.construct(data, rev, query)
                self.assertEqual(list(objects.entries), ["lib/services/tool"])
                self.assertEqual(set(objects.trees), {"lib", "lib/services"})
                self.assertEqual(objects.files, {})
                inventory = objects.preflight(["lib/services/tool"])
                self.assertEqual(inventory["revision"], rev)
                self.assertEqual(inventory["files"], [{"path": "lib/services/tool", "mode": "100755",
                                                       "type": "blob", "objectId": "a" * width}])
                self.assertEqual([r["path"] for r in inventory["trees"]], ["lib", "lib/services"])
                self.assert_no_blobs(query)

    def test_lock_policy_refuses_before_any_payload(self):
        for width in (40, 64):
            for mode, kind in (("100644", "blob"), ("120000", "blob"), ("040000", "tree")):
                with self.subTest(width=width, mode=mode):
                    data = self.records([(mode, kind, "a" * width, "Cargo.lock.nix")])
                    query = self.query_tree(data, "b" * width)
                    objects = self.construct(data, "b" * width, query)
                    query.reset_mock()
                    with patch.object(objects, "read", side_effect=AssertionError("payload read")) as read:
                        with self.assertRaisesRegex(ValueError, "unsupported-cargo-lock-policy"):
                            mirror.generate(objects, Path("/uncreated-mirror-scratch"), "pkgs/a")
                        read.assert_not_called()
                    query.assert_not_called()

    def test_selected_unsafe_modes_refuse_before_blob_read(self):
        path = "lib/services/module.nix"
        for width in (40, 64):
            for mode, kind in (("120000", "blob"), ("160000", "commit"),
                               ("100600", "blob"), ("100644", "tree")):
                with self.subTest(width=width, mode=mode, kind=kind):
                    objects = self.memory_objects(width, {path: b"RAM"})
                    objects.entries[path] = (mode, kind, "a" * width)
                    with self.assertRaisesRegex(ValueError, "unsafe source mode"):
                        objects.read(path)
                    objects.git.assert_not_called()
                    self.assertEqual(objects.files, {})

    def test_alias_missing_directory_and_bad_ids_refuse_prebody(self):
        path = "lib/services/module.nix"
        for width in (40, 64):
            for fault in ("alias", "missing-directory", "blob-id", "tree-id", "tree-mode"):
                with self.subTest(width=width, fault=fault):
                    objects = self.memory_objects(width, {path: b"RAM"})
                    if fault == "alias":
                        objects.entries["lib/services"] = ("100644", "blob", "a" * width)
                    elif fault == "missing-directory":
                        del objects.trees["lib/services"]
                    elif fault == "blob-id":
                        objects.entries[path] = ("100644", "blob", "bad")
                    elif fault == "tree-id":
                        objects.trees["lib/services"] = ("040000", "tree", "bad")
                    else:
                        objects.trees["lib/services"] = ("100644", "blob", "a" * width)
                    with self.assertRaises(ValueError):
                        objects.read(path)
                    objects.git.assert_not_called()

    def test_scoped_path_aliases_refuse_before_payload(self):
        for path in ("lib/services/../escape", "lib/services//alias", "lib/.git/file", "/absolute"):
            with self.subTest(path=path):
                objects = self.memory_objects(files={path: b"RAM"})
                with self.assertRaises(ValueError):
                    objects.read(path)
                objects.git.assert_not_called()

    def test_canonical_inventory_covers_root_and_owned_resources(self):
        for width in (40, 64):
            with self.subTest(width=width):
                files = {path: b"RAM" for path in (*mirror.ROOT_METADATA, "flake.lock",
                         "lib/flake/rust-export.nix", "lib/services/auth/private.rs")}
                objects = self.memory_objects(width, files)
                objects.trees["lib/services/empty"] = ("040000", "tree", "e" * width)
                inventory = objects.preflight(reversed(list(files)), ["lib/services/empty"])
                self.assertEqual([r["path"] for r in inventory["files"]], sorted(files))
                self.assertEqual([r["path"] for r in inventory["trees"]], sorted(objects.trees))
                for row in inventory["files"] + inventory["trees"]:
                    self.assertEqual(set(row), {"path", "mode", "type", "objectId"})
                    self.assertEqual(len(row["objectId"]), width)
                objects.git.assert_not_called()

    def test_generated_stamp_emits_exact_selected_metadata(self):
        contract = {"version": 1, "supportSources": ["lib/flake", "lib/services"],
                    "excludeSupportSources": ["lib/flake/tests"]}
        for width in (40, 64):
            with self.subTest(width=width):
                source = sources()
                source["lib/services/auth/private.rs"] = b"// public RAM module\n"
                objects = self.memory_objects(width, source)
                objects.trees["lib/services/empty"] = ("040000", "tree", "e" * width)
                planner = Mock(return_value={"supported": True, "reasons": [],
                    "plan": {"components": [["pkgs/a", "pkgs/b"], ["pkgs/unrelated"]]}})
                validator = Mock(return_value={"validated": True})
                with patch.object(mirror, "source_contract", return_value=contract), \
                        patch.object(Path, "mkdir"), patch.object(mirror, "materialize"), \
                        patch.object(mirror.tempfile, "mkdtemp", return_value="/rust-mirror-ram/validation"):
                    generated = mirror.generate(objects, Path("/rust-mirror-ram/source"), "pkgs/a",
                                                _planner=planner, _validator=validator)
                validator.assert_called_once()
                stamp = mirror.parse_json(generated[mirror.STAMP][0])
                selected = set(generated) - {mirror.STAMP, "flake.nix"}
                selected_trees = {p for p in objects.trees if mirror.support_path(p, contract) or
                                  any(p == d or p.startswith(d + "/") for d in ("pkgs/a", "pkgs/b"))}
                self.assertEqual(stamp["pinnedSourceInventory"], objects.preflight(selected, selected_trees))
                self.assertEqual(stamp["sourceContract"], contract)
                self.assertEqual(stamp["selection"]["memberDirs"], ["pkgs/a", "pkgs/b"])
                self.assertIn("lib/flake/resources/payload.json", selected)
                self.assertIn("lib/services/auth/private.rs", selected)
                self.assertFalse(any(p.startswith("lib/flake/tests/") for p in selected))
                self.assertNotIn("pkgs/unrelated/src/lib.rs", selected)
                self.assertTrue(set(mirror.ROOT_METADATA) <= selected)
                self.assertNotIn(mirror.STAMP, stamp["files"])
                self.assertEqual(stamp["files"]["lib/flake/pkg-helper.sh"]["mode"], 0o755)
                original_lock_id = objects.entries["flake.lock"][2]
                lock_row = next(r for r in stamp["pinnedSourceInventory"]["files"] if r["path"] == "flake.lock")
                self.assertEqual(lock_row["objectId"], original_lock_id)
                self.assertNotIn("unrelated", mirror.parse_json(generated["flake.lock"][0])["nodes"])

    def test_required_root_metadata_and_declaration_cannot_be_omitted(self):
        for missing in (*mirror.ROOT_METADATA, mirror.CONTRACT):
            with self.subTest(missing=missing):
                files = sources()
                del files[missing]
                objects = self.memory_objects(files=files)
                with self.assertRaisesRegex(ValueError, "missing pinned source"):
                    objects.preflight([*mirror.ROOT_METADATA, mirror.CONTRACT])
                objects.git.assert_not_called()


class MirrorTests(unittest.TestCase):
    def setUp(self):
        PRIVATE.mkdir(parents=True, exist_ok=True)
        self.base = Path(tempfile.mkdtemp(prefix="unit-", dir=PRIVATE))
        self.fixture = Fixture(self.base, sources())
        self.snapshot = self.base / "snapshot"
        self.snapshot.mkdir()
        self.output = self.base / "mirror"

    def tearDown(self):
        if not any(test is self for test, _ in self._outcome.result.failures + self._outcome.result.errors):
            shutil.rmtree(self.base)
        else:
            print(f"retained private fixture: {self.base}")

    def generate(self, fixture=None, **kwargs):
        return mirror.generate((fixture or self.fixture).objects(), self.snapshot, "pkgs/a",
                               _planner=kwargs.pop("_planner", fake_plan),
                               _validator=kwargs.pop("_validator", lambda *_: {"validated": True}), **kwargs)

    def test_layout_scope_modes_and_provenance(self):
        files = self.generate()
        self.assertEqual(files["pkgs/a/tool"], (b"binary\0bytes\xff", 0o755))
        self.assertEqual(files["lib/flake/pkg-helper.sh"][1], 0o755)
        for p in (mirror.CONTRACT, mirror.ENTRY, mirror.PLANNER, "lib/services/module.nix",
                  "pkgs/a/default.nix", "pkgs/a/flake.nix", *mirror.ROOT_METADATA):
            self.assertIn(p, files)
        self.assertNotIn("pkgs/unrelated/Cargo.toml", files)
        self.assertNotIn("lib/ext/not-owned.nix", files)
        self.assertFalse(any(p.startswith("data/") for p in files))
        stamp = mirror.parse_json(files[mirror.STAMP][0])
        self.assertEqual(stamp["revision"], self.fixture.rev)
        self.assertEqual(stamp["sourceContract"]["supportSources"], ["lib/flake", "lib/services"])
        self.assertNotIn(mirror.STAMP, stamp["files"])
        self.assertEqual(stamp["sourceContract"]["excludeSupportSources"], ["lib/flake/tests"])
        self.assertFalse(any(p.startswith("lib/flake/tests/") for p in files))

    def test_declared_support_preserves_formal_calls_and_builtin_aliases(self):
        for body in (
            b'let src = ../..; reader = file: '
            b'builtins.readFile (file + "/lib/flake/resources/payload.json"); in reader src',
            b'let src = ../..; read = builtins.readFile; in read (src + "/lib/flake/resources/payload.json")',
        ):
            files = self.generate(self.fixture.revise({"lib/flake/helper.nix": body}))
            self.assertEqual(files["lib/flake/helper.nix"][0], body)
            self.assertEqual(files["lib/flake/resources/payload.json"][0],
                             sources()["lib/flake/resources/payload.json"])

    def test_contract_is_pinned_not_live(self):
        missing = self.fixture.revise({mirror.CONTRACT: None})
        live = missing.repo / mirror.CONTRACT
        live.parent.mkdir(parents=True)
        live.write_bytes(sources()[mirror.CONTRACT])
        with self.assertRaisesRegex(ValueError, "missing pinned source"):
            self.generate(missing)

    def test_contract_schema_versions_and_boundaries(self):
        for body in (b'{ version = 2; supportSources = ["lib/flake"]; }',
                     b'{ version = true; supportSources = ["lib/flake"]; }',
                     b'{ version = 1; supportSources = []; }',
                     b'{ version = 1; supportSources = ["lib/flake" "lib/flake"]; }',
                     b'{ version = 1; supportSources = ["lib" "lib/flake"]; }',
                     b'{ version = 1; supportSources = ["data/secrets"]; }',
                     b'{ version = 1; supportSources = ["lib/.git"]; }',
                     b'{ version = 1; supportSources = ["lib/services"]; }',
                     b'{ version = 1; supportSources = ["lib/flake"]; extra = 1; }'):
            with self.subTest(body=body), self.assertRaises(ValueError):
                self.generate(self.fixture.revise({mirror.CONTRACT: body}))

    def test_optional_exclusions_default_to_empty(self):
        contract = b'{ version = 1; supportSources = ["lib/flake" "lib/services"]; }'
        files = self.generate(self.fixture.revise({mirror.CONTRACT: contract,
                                                  "lib/flake/tests/source-link": None}))
        self.assertIn("lib/flake/tests/fixture.txt", files)
        self.assertEqual(mirror.parse_json(files[mirror.STAMP][0])["sourceContract"]
                         ["excludeSupportSources"], [])

    def test_exclusion_schema_boundaries(self):
        for value in ('["lib/flake"]', '["Cargo.toml"]', '["pkgs/a"]',
                      '["lib/flake/tests" "lib/flake/tests"]',
                      '["lib/flake/tests" "lib/flake/tests/fixtures"]',
                      '["lib/flake/../tests"]', '["lib/flake/.git"]',
                      '["lib/flake/rust-closures.nix"]', 'null'):
            contract = ('{ version = 1; supportSources = ["lib/flake" "lib/services"]; '
                        f'excludeSupportSources = {value}; }}').encode()
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.generate(self.fixture.revise({mirror.CONTRACT: contract}))

    def test_exclusions_do_not_bypass_workspace_member_preflight(self):
        contract = (b'{ version = 1; supportSources = ["lib/flake" "lib/services" "pkgs"]; '
                    b'excludeSupportSources = ["lib/flake/tests" "pkgs/a"]; }')
        objects = self.fixture.revise({mirror.CONTRACT: contract,
                                      "pkgs/a/source-link": (b"outside", "120000")}).objects()
        with patch.object(objects, "read", wraps=objects.read) as reader:
            with self.assertRaisesRegex(ValueError, "unsafe source mode"):
                mirror.generate(objects, self.snapshot, "pkgs/a", _planner=fake_plan,
                                _validator=lambda *_: None)
            self.assertEqual([c.args[0] for c in reader.call_args_list],
                             [mirror.CONTRACT, "Cargo.toml"])
        # The same exclusion cannot erase a valid selected member either.
        contract = contract.replace(b'"pkgs/a"', b'"pkgs/a" "pkgs/unrelated"')
        files = self.generate(self.fixture.revise({mirror.CONTRACT: contract}))
        self.assertEqual(files["pkgs/a/tool"], (b"binary\0bytes\xff", 0o755))
        self.assertIn("pkgs/a/default.nix", files)

    def test_contract_cannot_read_host_or_worktree_files(self):
        host = self.base / "outside-contract.nix"
        host.write_bytes(sources()[mirror.CONTRACT])
        bad = self.fixture.revise({mirror.CONTRACT: f'import {mirror.nix_string(str(host))}'.encode()})
        with self.assertRaisesRegex(ValueError, "forbidden|restricted"):
            self.generate(bad)

    def test_unselected_payload_and_unowned_blobs_never_fetched(self):
        objects = self.fixture.objects()
        blocked = {objects.entries[p][2] for p in (
            "pkgs/unrelated/src/lib.rs", "lib/ext/not-owned.nix", "data/secrets/synthetic.key",
            "lib/flake/tests/fixture.txt", "lib/flake/tests/source-link")}
        original = objects.git
        def git(*args):
            if args[:2] == ("cat-file", "blob") and args[2] in blocked:
                self.fail("nonreferenced payload/secret read")
            return original(*args)
        with patch.object(objects, "git", side_effect=git):
            mirror.generate(objects, self.snapshot, "pkgs/a", _planner=fake_plan, _validator=lambda *_: None)

    def test_scope_preflight_before_support_payload_reads(self):
        for path, mode in (("lib/services/unsafe", "120000"), ("lib/flake/submodule", "160000"),
                           ("pkgs/unrelated/unsafe", "120000"), ("lib/flake/.git/file", "100644"),
                           ("lib/services/bad\nname", "100644"),
                           ("lib/flake/data/secrets/synthetic.key", "100644")):
            fixture = self.fixture.revise({path: (b"synthetic", mode)})
            objects = fixture.objects()
            with patch.object(objects, "read", wraps=objects.read) as reader:
                with self.subTest(path=path), self.assertRaises(ValueError):
                    mirror.generate(objects, self.snapshot, "pkgs/a", _planner=fake_plan, _validator=lambda *_: None)
                self.assertEqual([c.args[0] for c in reader.call_args_list], [mirror.CONTRACT, "Cargo.toml"])

    def test_ancestor_configs_reject_before_payload(self):
        for path in (".cargo/config.toml", "pkgs/.cargo/config.toml", "pkgs/b/src/.cargo/config"):
            objects = self.fixture.revise({path: b"unsupported"}).objects()
            with patch.object(objects, "read", wraps=objects.read) as reader:
                with self.assertRaisesRegex(ValueError, "local-cargo-config"):
                    mirror.generate(objects, self.snapshot, "pkgs/a", _planner=fake_plan, _validator=lambda *_: None)
                self.assertEqual([c.args[0] for c in reader.call_args_list], [mirror.CONTRACT, "Cargo.toml"])

    def test_secret_paths_reject_without_blob_read(self):
        objects = self.fixture.objects()
        with patch.object(objects, "git", side_effect=AssertionError("content read")):
            for path in ("data", "data/secrets", "data/secrets/synthetic.key"):
                with self.assertRaisesRegex(ValueError, "secrets"):
                    objects.read(path)

    def test_reserved_stamp_and_generated_root_collisions(self):
        for name in (mirror.STAMP, "flake.nix"):
            body = (f'{{ version = 1; supportSources = ["lib/flake" "lib/services" "{name}"]; '
                    'excludeSupportSources = ["lib/flake/tests"]; }').encode()
            fixture = self.fixture.revise({mirror.CONTRACT: body, name: b'"pinned original"'})
            with self.assertRaisesRegex(ValueError, "reserved"):
                self.generate(fixture)

    def test_root_stamp_reserved_even_outside_support_scope(self):
        fixture = self.fixture.revise({mirror.STAMP: b'"pinned original"'})
        with self.assertRaisesRegex(ValueError, "reserved provenance stamp"):
            self.generate(fixture)

    def test_cli_secret_locations_reject_before_git(self):
        for repo, output in (
                (self.base / "data/secrets/source", self.base / "output"),
                (self.fixture.repo, self.base / "outside/data/secrets/output")):
            with patch.object(mirror, "Objects", side_effect=AssertionError("Git inspection")), \
                    patch.object(mirror.sys, "stderr"):
                self.assertEqual(mirror.main([
                    "--repo", str(repo), "--rev", self.fixture.rev,
                    "--member", "pkgs/a", "--output", str(output), "--check",
                ]), 1)

    def test_explicit_commit_and_modes(self):
        for rev in ("HEAD", self.fixture.rev[:12], "--help", "1" * 40 + "^{commit}"):
            with self.assertRaises(ValueError):
                mirror.Objects(self.fixture.repo, rev)
        blob = self.fixture.git("hash-object", "-w", "--stdin", data=b"blob").strip().decode()
        with self.assertRaisesRegex(ValueError, "not a commit"):
            mirror.Objects(self.fixture.repo, blob)

    def test_git_environment_and_worktree_not_authority(self):
        live = self.fixture.repo / "Cargo.lock"
        live.write_bytes(b"wrong")
        with patch.dict(os.environ, {"GIT_DIR": "/invalid", "GIT_WORK_TREE": "/invalid"}):
            self.assertEqual(self.fixture.objects().read("Cargo.lock"), sources()["Cargo.lock"])

    def test_unsafe_paths(self):
        for path in ("../pkgs/a", "/pkgs/a", "pkgs//a", "pkgs/a\n", "pkgs/.git/a", "pkgs/a*", "pkgs\\a"):
            with self.assertRaises(ValueError):
                mirror.safe_path(path)

    def test_missing_selected_definition_and_unknown_member(self):
        with self.assertRaisesRegex(ValueError, "member definition"):
            self.generate(self.fixture.revise({"pkgs/b/default.nix": None}))
        with self.assertRaisesRegex(ValueError, "member.*directory"):
            mirror.generate(self.fixture.objects(), self.snapshot, "a", _planner=fake_plan, _validator=lambda *_: None)

    def test_unsupported_planner_and_scoped_failure(self):
        for scoped_only in (False, True):
            def planner(snapshot, member_dirs=None):
                if not scoped_only or member_dirs is not None:
                    return {"supported": False, "reasons": ["unsupported"]}
                return fake_plan(snapshot)
            with self.assertRaisesRegex(ValueError, "unsupported"):
                self.generate(_planner=planner)
        self.assertFalse(self.output.exists())

    def test_validator_mandatory_before_inventory_and_publication(self):
        with self.assertRaisesRegex(ValueError, "native failure"):
            self.generate(_validator=lambda *_: mirror.require(False, "native failure"))
        self.assertFalse(self.output.exists())
        with patch.object(mirror, "generate", side_effect=ValueError("validation fails")), \
                patch.object(mirror, "publish", side_effect=AssertionError("publication")), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(mirror.main(self.cli_args() + ["--write"]), 1)

    def test_lock_pruning_and_original_refs(self):
        lock = lock_fixture()
        lock["nodes"]["crane"]["original"]["ref"] = "v0.24.0"
        pruned = mirror.prune_lock(lock)
        self.assertNotIn("unrelated", pruned["nodes"])
        self.assertEqual(pruned["nodes"]["flake-utils"]["inputs"]["nixpkgs"], "nixpkgs")
        flake = mirror.render_export({"memberDirs": ["pkgs/a"], "primaryMember": "pkgs/a"}, pruned)
        self.assertIn(b"github:fixture/crane/v0.24.0", flake["flake.nix"][0])

    def test_bad_lock_and_json(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            mirror.parse_json('{"version":7,"version":7}')
        for change in ("follows", "graph", "missing", "mutable"):
            lock = lock_fixture()
            if change == "follows": lock["nodes"]["root"]["inputs"]["nixpkgs"] = ["nixpkgs"]
            if change == "graph": lock["nodes"]["crane"]["inputs"] = {"self": "crane"}
            if change == "missing": lock["nodes"]["crane"]["inputs"] = {"x": "missing"}
            if change == "mutable": del lock["nodes"]["crane"]["locked"]["rev"]
            with self.assertRaises((ValueError, KeyError)):
                mirror.prune_lock(lock)

    def test_cold_cache_clear_failure_no_fetcher(self):
        commands = []
        def run(args, **kwargs):
            commands.append(args)
            if args[0] == "nix-store": return b"/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source\n"
            raise ValueError("not valid")
        with patch.object(mirror, "run", side_effect=run), self.assertRaisesRegex(ValueError, "uncached locked input"):
            mirror.cached_inputs(mirror.prune_lock(lock_fixture()))
        self.assertFalse(any("fetch" in str(a) or "flake" in a for args in commands for a in args))

    def test_evaluator_has_narrow_allowlist(self):
        with patch.object(mirror, "run", return_value=b'{}') as runner:
            mirror.evaluate("{}", [self.snapshot], self.base)
        argv = runner.call_args.args[0]
        self.assertIn("--offline", argv)
        self.assertIn("--restrict-eval", argv)
        self.assertIn("allow-import-from-derivation", argv)
        allowed = [argv[i + 1].split("=", 1)[1] for i, value in enumerate(argv) if value == "-I"]
        self.assertIn(str(self.snapshot), allowed)
        self.assertNotIn(str(self.base), allowed)
        self.assertFalse(any("path:" in a for a in argv))

    def test_atomic_creation_replacement_and_check(self):
        files = self.generate()
        mirror.publish(self.output, files, self.base)
        mirror.publish(self.output, files, self.base, check=True)
        mirror.publish(self.output, files, self.base)
        self.assertEqual(mirror.inspect_output(self.output), files)

    def test_drift_never_overwritten(self):
        files = self.generate()
        mirror.materialize(self.output, files)
        target = self.output / "Cargo.lock"
        target.write_bytes(b"user edit")
        for check in (False, True):
            with self.assertRaisesRegex(ValueError, "modified|stale"):
                mirror.publish(self.output, files, self.base, check=check)
        self.assertEqual(target.read_bytes(), b"user edit")

    def test_output_modes_extra_files_and_directories(self):
        files = self.generate()
        mirror.materialize(self.output, files)
        target = self.output / "pkgs/a/tool"
        target.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "stale"):
            mirror.publish(self.output, files, self.base, check=True)
        (self.output / "empty").mkdir()
        with self.assertRaisesRegex(ValueError, "extra output directories"):
            mirror.inspect_output(self.output)

    def test_unowned_output_not_read(self):
        self.output.mkdir()
        (self.output / "user.key").write_bytes(b"synthetic private fixture")
        files = self.generate()
        with patch.object(Path, "read_bytes", side_effect=AssertionError("content read")):
            for check in (False, True):
                with self.assertRaisesRegex(ValueError, "non-generator-owned"):
                    mirror.publish(self.output, files, self.base, check=check)

    def test_output_links_rejected(self):
        self.output.mkdir()
        target = self.output / "file"
        target.symlink_to(self.base / "absent")
        with self.assertRaisesRegex(ValueError, "symlink"):
            mirror.inspect_output(self.output)
        target.unlink()
        target.write_bytes(b"bytes")
        os.link(target, self.output / "hardlink")
        with self.assertRaisesRegex(ValueError, "unsafe output file"):
            mirror.inspect_output(self.output)

    def test_output_boundaries_and_secret_locations_before_reads(self):
        objects = self.fixture.objects()
        for path in (objects.repo, objects.repo / "nested", self.base, Path.home(), Path("/"),
                     self.base / ".git/output", self.base / "data/secrets/output"):
            with self.assertRaises(ValueError):
                mirror.output_path(path, objects)
        alias = self.base / "alias"
        alias.symlink_to(self.base, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "ancestor"):
            mirror.output_path(alias / "output", objects)
        with patch.object(mirror, "run", side_effect=AssertionError("Git read")):
            secret = self.base / "data/secrets/repo"
            secret.mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, "secrets"):
                mirror.Objects(secret, self.fixture.rev)

    def test_subdirectory_cannot_narrow_git_root(self):
        fixture = Fixture(self.base / "nonbare", sources(), bare=False)
        subdir = fixture.repo / "nested"
        subdir.mkdir()
        objects = mirror.Objects(subdir, fixture.rev)
        self.assertEqual(objects.repo, fixture.repo)
        with self.assertRaisesRegex(ValueError, "inside source"):
            mirror.output_path(fixture.repo / "output", objects)

    def cli_args(self):
        return ["--repo", str(self.fixture.repo), "--rev", self.fixture.rev,
                "--member", "pkgs/a", "--output", str(self.output)]

    def test_cli_options_help_and_safe_tmp_creation(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            mirror.main([])
        files = self.generate()
        mirror.materialize(self.output, files)
        with patch.object(mirror, "generate", return_value=files), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(mirror.main(self.cli_args() + ["--check"]), 0)
        self.assertTrue((self.fixture.repo / "tmp").is_dir())
        shutil.rmtree(self.fixture.repo / "tmp")
        (self.fixture.repo / "tmp").symlink_to(self.base, target_is_directory=True)
        with patch.object(mirror, "generate", side_effect=AssertionError("generation")), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(mirror.main(self.cli_args() + ["--write"]), 1)

    def test_subprocesses_bounded_no_shell_no_lazy_fetch(self):
        result = subprocess.CompletedProcess([], 0, b"okay", b"")
        with patch.object(mirror.subprocess, "run", return_value=result) as runner:
            mirror.run(["git", "version"])
        self.assertEqual(runner.call_args.kwargs["timeout"], 60)
        self.assertNotIn("shell", runner.call_args.kwargs)
        self.assertEqual(runner.call_args.kwargs["env"]["GIT_NO_LAZY_FETCH"], "1")


class CachedExportTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("nix"):
            raise unittest.SkipTest("Nix absent; actual export validation not exercised")
        cls.lock = mirror.prune_lock(mirror.parse_json((ROOT / "flake.lock").read_bytes()))
        try:
            mirror.cached_inputs(cls.lock)
        except ValueError as error:
            raise unittest.SkipTest(str(error))
        PRIVATE.mkdir(parents=True, exist_ok=True)
        cls.base = Path(tempfile.mkdtemp(prefix="cached-export-", dir=PRIVATE))
        files = {}
        # These two declared ownership areas only; never archive/list real Git.
        for scope in ("lib/flake", "lib/services"):
            for path in (ROOT / scope).rglob("*"):
                info = path.lstat()
                if stat.S_ISDIR(info.st_mode): continue
                rel = path.relative_to(ROOT).as_posix()
                mirror.safe_path(rel)
                if stat.S_ISLNK(info.st_mode):
                    # Preserve link metadata and link text as immutable objects;
                    # never follow links or omit entries from this revision.
                    files[rel] = (os.fsencode(os.readlink(path)), "120000")
                elif stat.S_ISREG(info.st_mode):
                    files[rel] = (path.read_bytes(), "100755" if info.st_mode & 0o111 else "100644")
                else:
                    raise AssertionError(f"nonregular fixture input: {path}")
        fixture_root = ROOT / "lib/flake/tests/fixtures/rust-exports"
        for path in fixture_root.rglob("*"):
            if path.is_file(): files[path.relative_to(fixture_root).as_posix()] = path.read_bytes()
        files["flake.lock"] = (ROOT / "flake.lock").read_bytes()
        files[".gitignore"] = b"target\n"
        files["treefmt.toml"] = b"# fixture\n"
        cls.fixture = Fixture(cls.base, files)
        cls.snapshot = cls.base / "snapshot"
        cls.snapshot.mkdir()
        cls.generated = mirror.generate(cls.fixture.objects(), cls.snapshot, "members/manager")
        cls.output = cls.base / "mirror"
        mirror.publish(cls.output, cls.generated, cls.base)
        # Deliberately retain this private fixture for MAIN's final CLI matrix.
        (cls.base / "revision").write_text(cls.fixture.rev + "\n")
        print(f"retained cached integration fixture: {cls.base}")

    def variant(self, changes):
        fixture = self.fixture.revise(changes)
        snapshot = Path(tempfile.mkdtemp(prefix="variant-", dir=self.base))
        return mirror.generate(fixture.objects(), snapshot, "members/manager")

    def test_actual_cli_check_and_native_evidence(self):
        args = [mirror.sys.executable, "-B", str(ROOT / "scripts/rust-fabric/mirror/rust-mirror.py"),
                "--repo", str(self.fixture.repo), "--rev", self.fixture.rev,
                "--member", "members/manager", "--output", str(self.output)]
        for mode, message in (("--write", "mirror written"), ("--check", "mirror matches")):
            result = subprocess.run(args + [mode], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(message, result.stdout)
        evidence = mirror.validate_export(self.output, self.lock)
        self.assertTrue(evidence["validated"])
        self.assertIn("manager", evidence["packages"])
        self.assertEqual(evidence["component"]["memberDirs"], ["members/agent", "members/manager"])

    def test_excluded_symlinks_present_in_revision_but_never_read(self):
        objects = self.fixture.objects()
        excluded = {p for p in objects.entries if p.startswith("lib/flake/tests/")}
        links = {p for p in excluded if objects.entries[p][0] == "120000"}
        self.assertEqual(len(links), 6)
        # Identical blobs may legitimately occur in selected member/root files.
        blocked = ({objects.entries[p][2] for p in excluded} -
                   {entry[2] for p, entry in objects.entries.items() if p not in excluded})
        original_git, original_read = objects.git, objects.read
        def git(*args):
            if args[:2] == ("cat-file", "blob") and args[2] in blocked:
                self.fail("excluded-only support blob read")
            return original_git(*args)
        def read(path):
            self.assertNotIn(path, excluded)
            return original_read(path)
        snapshot = Path(tempfile.mkdtemp(prefix="excluded-", dir=self.base))
        with patch.object(objects, "git", side_effect=git), patch.object(objects, "read", side_effect=read):
            files = mirror.generate(objects, snapshot, "members/manager")
        self.assertFalse(excluded & set(files))
        self.assertFalse((self.output / "lib/flake/tests").exists())

    def test_actual_formal_call_and_aliased_reader_copied(self):
        original = self.fixture.source_files["members/manager/default.nix"]
        for read in (
            'let root = ../..; reader = file: '
            'builtins.readFile (file + "/lib/flake/review-payload.txt"); in reader root',
            'let root = ../..; read = builtins.readFile; in read (root + "/lib/flake/review-payload.txt")',
        ):
            body = ('assert (' + read + ') == "payload";\n').encode() + original
            files = self.variant({"members/manager/default.nix": body, "lib/flake/review-payload.txt": b"payload"})
            self.assertEqual(files["lib/flake/review-payload.txt"][0], b"payload")
            self.assertEqual(files["members/manager/default.nix"][0], body)

    def test_actual_missing_outside_scope_and_absolute_host_reads_fail(self):
        original = self.fixture.source_files["members/manager/default.nix"]
        host = self.base / "host-payload.txt"
        host.write_bytes(b"payload")
        for resource, changes in (
            ('../.. + "/lib/flake/absent.txt"', {}),
            ('../.. + "/lib/ext/review-payload.txt"', {"lib/ext/review-payload.txt": b"payload"}),
            ('../.. + "/lib/flake/tests/review-payload.txt"',
             {"lib/flake/tests/review-payload.txt": b"payload"}),
            (mirror.nix_string(str(host)), {}),
            (mirror.nix_string(str(self.snapshot / "members/peer/Cargo.toml")), {}),
        ):
            body = f'assert builtins.readFile ({resource}) == "payload";\n'.encode() + original
            with self.subTest(resource=resource), self.assertRaisesRegex(
                    ValueError, "does not exist|forbidden|restricted"):
                self.variant(dict(changes, **{"members/manager/default.nix": body}))

    def test_actual_cold_cache_rejects_before_publication(self):
        lock = mirror.parse_json(self.fixture.source_files["flake.lock"])
        crane = lock["nodes"][lock["nodes"][lock["root"]]["inputs"]["crane"]]
        crane["locked"]["narHash"] = lock_fixture()["nodes"]["crane"]["locked"]["narHash"]
        with self.assertRaisesRegex(ValueError, "uncached locked input"):
            self.variant({"flake.lock": json.dumps(lock).encode()})

    def test_dormant_functions_are_explicitly_not_certified(self):
        original = self.fixture.source_files["members/manager/default.nix"]
        body = b'let dormant = _: builtins.readFile "/nonexistent/review-host"; in\n' + original
        files = self.variant({"members/manager/default.nix": body})
        self.assertEqual(files["members/manager/default.nix"][0], body)


if __name__ == "__main__":
    unittest.main()
