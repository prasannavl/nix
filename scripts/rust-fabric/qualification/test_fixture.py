#!/usr/bin/env python3
"""Pure declaration/source checks and bounded generator filesystem tests.

These tests never invoke Cargo, Rust, Nix or a network/provider command.
They check fixture intent, not resolved units or native build acceptance.
"""

from contextlib import ExitStack, redirect_stderr, redirect_stdout
import errno
import io
import os
from pathlib import Path
import tempfile
import tomllib
import types
import unittest
from unittest.mock import patch

import fixture


DEPENDENCY_SCOPES = ("dependencies", "build-dependencies", "dev-dependencies")
IO_GUARDS = ("builtins.open", "io.open", "os.open", "os.stat", "os.lstat", "os.mkdir")


def manifests(files: dict[str, bytes]) -> dict[str, dict]:
    return {
        path: tomllib.loads(files[f"{path}/Cargo.toml"].decode("utf-8"))
        for path in fixture.MEMBER_PATHS
    }


def local_edges(declarations: dict[str, dict]) -> dict[str, set[str]]:
    edges = {}
    for member_path, manifest in declarations.items():
        dependencies = set()
        for scope in DEPENDENCY_SCOPES:
            for declaration in manifest.get(scope, {}).values():
                dependency = declaration["path"].removeprefix("../")
                dependencies.add(f"members/{dependency}")
        edges[member_path] = dependencies
    return edges


def declared_closure(member_path: str, edges: dict[str, set[str]]) -> set[str]:
    closure = {member_path}
    for dependency in edges[member_path]:
        closure.update(declared_closure(dependency, edges))
    return closure


class DeclarationTests(unittest.TestCase):
    def setUp(self):
        self.files = fixture.build_files()
        self.manifests = manifests(self.files)

    def test_seven_sorted_members_and_minimal_root_schema(self):
        root = tomllib.loads(self.files["Cargo.toml"].decode("utf-8"))
        self.assertEqual(set(root), {"workspace"})
        self.assertEqual(set(root["workspace"]), {"resolver", "members"})
        self.assertEqual(root["workspace"]["resolver"], "2")
        members = root["workspace"]["members"]
        self.assertEqual(members, sorted(members))
        self.assertEqual(members, list(fixture.MEMBER_PATHS))
        self.assertEqual(len(set(members)), 7)
        self.assertEqual(
            {path.removeprefix("members/") for path in members},
            {"leaf", "branch", "app", "build-helper", "macro", "dev-helper", "peer"},
        )
        lines = self.files["Cargo.toml"].decode("utf-8").splitlines()
        self.assertEqual(lines[2], "members = [")
        self.assertEqual(lines[3:10], [f'    "{member}",' for member in members])

    def test_packages_are_unambiguous_local_versioned_declarations(self):
        names = set()
        allowed_sections = {"package", "features", "lib", *DEPENDENCY_SCOPES}
        for member_path, manifest in self.manifests.items():
            with self.subTest(member=member_path):
                self.assertLessEqual(set(manifest), allowed_sections)
                member = member_path.removeprefix("members/")
                self.assertEqual(
                    manifest["package"],
                    {"name": f"g4-{member}", "version": "0.1.0", "edition": "2021"},
                )
                names.add(manifest["package"]["name"])
                for scope in DEPENDENCY_SCOPES:
                    for name, dependency in manifest.get(scope, {}).items():
                        self.assertEqual(dependency["version"], "0.1.0")
                        self.assertEqual(dependency["path"], f'../{name.removeprefix("g4-")}')
                        self.assertLessEqual(
                            set(dependency), {"path", "version", "default-features", "features"}
                        )
                        destination = f'members/{dependency["path"].removeprefix("../")}'
                        self.assertIn(destination, self.manifests)
                        self.assertEqual(self.manifests[destination]["package"]["name"], name)
        self.assertEqual(len(names), 7)
        self.assertEqual(fixture.APP_PACKAGE_NAME, "g4-app")
        self.assertEqual(self.manifests["members/macro"]["lib"], {"proc-macro": True})

    def test_normal_build_macro_dev_scope_topology(self):
        app = self.manifests["members/app"]
        self.assertEqual(set(app["dependencies"]), {"g4-branch", "g4-macro"})
        self.assertEqual(set(app["build-dependencies"]), {"g4-build-helper"})
        self.assertEqual(set(app["dev-dependencies"]), {"g4-dev-helper"})
        for member, feature in (
            ("branch", "normal"),
            ("build-helper", "build"),
            ("macro", "macro"),
            ("dev-helper", "dev"),
        ):
            manifest = self.manifests[f"members/{member}"]
            self.assertEqual(
                manifest["dependencies"],
                {"g4-leaf": {
                    "path": "../leaf",
                    "version": "0.1.0",
                    "default-features": False,
                    "features": [feature],
                }},
            )
            self.assertNotIn("build-dependencies", manifest)
            self.assertNotIn("dev-dependencies", manifest)
        for member in ("leaf", "peer"):
            for scope in DEPENDENCY_SCOPES:
                self.assertNotIn(scope, self.manifests[f"members/{member}"])
        self.assertEqual(
            self.manifests["members/leaf"]["features"],
            {"default": [], "normal": [], "build": [], "macro": [], "dev": []},
        )

    def test_acyclic_declared_closures_and_strict_subset_candidates(self):
        edges = local_edges(self.manifests)
        visited = set()
        active = set()

        def visit(member):
            self.assertNotIn(member, active, "fixture declarations must be acyclic")
            if member in visited:
                return
            active.add(member)
            for dependency in edges[member]:
                visit(dependency)
            active.remove(member)
            visited.add(member)

        for member in edges:
            visit(member)
        self.assertEqual(len(visited), 7)
        closures = {member: declared_closure(member, edges) for member in edges}
        leaf = closures["members/leaf"]
        branch = closures["members/branch"]
        app = closures["members/app"]
        self.assertLess(leaf, branch)
        self.assertLess(branch, app)
        self.assertEqual(app, set(fixture.MEMBER_PATHS) - {"members/peer"})
        self.assertEqual(closures["members/peer"], {"members/peer"})
        candidates = [member for member in closures if closures[member] < app]
        ordered = sorted(candidates, key=lambda member: (-len(closures[member]), member))
        self.assertEqual(
            ordered,
            ["members/branch", "members/build-helper", "members/dev-helper",
             "members/macro", "members/leaf"],
        )
        # These are declared candidates, not an assertion about Nix selection.
        self.assertTrue(all(len(closures[member]) == 2 for member in ordered[:4]))

    def test_lock_v4_is_exact_declared_dependency_union(self):
        lock = tomllib.loads(self.files["Cargo.lock"].decode("utf-8"))
        self.assertEqual(set(lock), {"version", "package"})
        self.assertEqual(lock["version"], 4)
        packages = lock["package"]
        self.assertEqual(len(packages), 7)
        self.assertEqual([package["name"] for package in packages], sorted(
            manifest["package"]["name"] for manifest in self.manifests.values()
        ))
        by_name = {manifest["package"]["name"]: manifest for manifest in self.manifests.values()}
        for package in packages:
            with self.subTest(package=package["name"]):
                self.assertEqual(package["version"], "0.1.0")
                manifest = by_name[package["name"]]
                union = set()
                for scope in DEPENDENCY_SCOPES:
                    union.update(manifest.get(scope, {}))
                self.assertEqual(package.get("dependencies", []), sorted(union))
                expected_fields = {"name", "version"}
                if union:
                    expected_fields.add("dependencies")
                self.assertEqual(set(package), expected_fields)
        self.assertIn(b"Not a resolved feature/role/unit graph", self.files["Cargo.lock"])

    def test_exact_file_surface_has_no_hidden_inputs_or_inventory(self):
        expected_files = {"Cargo.toml", "Cargo.lock", "expected-output.txt"}
        for member_path in fixture.MEMBER_PATHS:
            expected_files.add(f"{member_path}/Cargo.toml")
            source_name = "main.rs" if member_path == "members/app" else "lib.rs"
            expected_files.add(f"{member_path}/src/{source_name}")
        expected_files.update({"members/app/build.rs", "members/app/build-input.txt"})
        self.assertEqual(set(self.files), expected_files)
        for path, content in self.files.items():
            self.assertIsInstance(content, bytes)
            self.assertFalse(Path(path).is_absolute())
            self.assertNotIn("..", Path(path).parts)
            self.assertTrue(content.endswith(b"\n"))


class SourceIntentTests(unittest.TestCase):
    def test_role_labels_are_safe_for_workspace_priming(self):
        files = fixture.build_files()
        source = files["members/leaf/src/lib.rs"].decode("utf-8")
        roles = ("normal", "build", "macro", "dev")
        for role in roles:
            self.assertIn(f'if cfg!(feature = "{role}") {{\n        roles.push("{role}");', source)
        self.assertEqual(
            sorted(roles, key=lambda role: source.index(f'roles.push("{role}")')),
            list(roles),
        )
        self.assertIn('roles.join("+")', source)
        self.assertIn('Vec<&str> = Vec::new()', source)
        for path, content in files.items():
            if path.endswith(".rs"):
                self.assertNotIn(b"compile_error!", content)
                self.assertNotIn(b"unsafe", content)
        for member in ("branch", "build-helper", "dev-helper"):
            self.assertIn(b"g4_leaf::role_label()", files[f"members/{member}/src/lib.rs"])

    def test_consumed_build_input_and_deterministic_host_macro(self):
        files = fixture.build_files()
        build = files["members/app/build.rs"].decode("utf-8")
        self.assertEqual(files["members/app/build-input.txt"], b"input-v1\n")
        self.assertIn('std::fs::read_to_string("build-input.txt")', build)
        self.assertIn('assert_eq!(marker, "input-v1")', build)
        self.assertIn("cargo:rerun-if-changed=build-input.txt", build)
        self.assertIn("cargo:rustc-env=G4_BUILD_MARKER={}:{}", build)
        self.assertIn("g4_build_helper::role_label()", build)
        app = files["members/app/src/main.rs"].decode("utf-8")
        self.assertIn('env!("G4_BUILD_MARKER")', app)
        self.assertIn("g4_macro::host_marker!()", app)
        self.assertIn('"source={};target={};build={};macro={}"', app)
        self.assertIn("g4_branch::source_marker()", app)
        macro = files["members/macro/src/lib.rs"].decode("utf-8")
        self.assertIn("#[proc_macro]", macro)
        self.assertIn("pub fn host_marker(_input: TokenStream) -> TokenStream", macro)
        self.assertIn("let marker = g4_leaf::role_label();", macro)
        self.assertIn('format!("{:?}", marker).parse()', macro)

    def test_app_tests_use_dev_helper_and_expect_host_target_separation(self):
        app = fixture.build_files()["members/app/src/main.rs"].decode("utf-8")
        self.assertIn("#[cfg(test)]", app)
        self.assertIn('assert_eq!(g4_branch::role_label(), "normal+dev")', app)
        self.assertIn('assert_eq!(g4_dev_helper::role_label(), "normal+dev")', app)
        self.assertIn('assert_eq!(BUILD_MARKER, "input-v1:build+macro")', app)
        self.assertIn('assert_eq!(MACRO_MARKER, "build+macro")', app)
        self.assertEqual(fixture.EXPECTED_TARGET_ROLES, "normal")
        self.assertEqual(fixture.EXPECTED_TEST_TARGET_ROLES, "normal+dev")
        self.assertEqual(fixture.EXPECTED_HOST_ROLES, "build+macro")

    def test_canonical_plain_output_for_every_variant(self):
        for variant in fixture.VARIANTS:
            with self.subTest(variant=variant):
                files = fixture.build_files(variant)
                self.assertEqual(
                    files["expected-output.txt"], fixture.EXPECTED_STDOUT[variant].encode()
                )
        self.assertEqual(
            fixture.EXPECTED_STDOUT["baseline"],
            "source=leaf-v1;target=normal;build=input-v1:build+macro;macro=build+macro\n",
        )
        self.assertEqual(
            fixture.EXPECTED_STDOUT["rust-edit"],
            fixture.EXPECTED_STDOUT["baseline"].replace("leaf-v1", "leaf-v2"),
        )


class VariantTests(unittest.TestCase):
    def test_only_intended_files_differ(self):
        baseline = fixture.build_files()
        expected_changes = {
            "rust-edit": {"members/leaf/src/lib.rs", "expected-output.txt"},
            "manifest-edit": {"members/leaf/Cargo.toml"},
            "lock-edit": {"Cargo.lock"},
        }
        for variant, expected in expected_changes.items():
            with self.subTest(variant=variant):
                changed = fixture.build_files(variant)
                self.assertEqual(set(changed), set(baseline))
                self.assertEqual(
                    {path for path in baseline if baseline[path] != changed[path]}, expected
                )
                for path in baseline:
                    if path.startswith("members/peer/"):
                        self.assertEqual(baseline[path], changed[path])
        self.assertEqual(fixture.build_files(), fixture.build_files("baseline"))

    def test_rust_edit_only_changes_observable_source_value(self):
        baseline = fixture.build_files()
        edited = fixture.build_files("rust-edit")
        path = "members/leaf/src/lib.rs"
        self.assertEqual(edited[path], baseline[path].replace(b"leaf-v1", b"leaf-v2"))

    def test_manifest_edit_adds_only_unused_feature(self):
        baseline = fixture.build_files()
        edited = fixture.build_files("manifest-edit")
        path = "members/leaf/Cargo.toml"
        self.assertEqual(edited[path], baseline[path] + b"unused-local-probe = []\n")
        self.assertEqual(tomllib.loads(edited[path].decode())["features"]["unused-local-probe"], [])

    def test_lock_edit_is_a_global_byte_probe_not_resolution_evidence(self):
        baseline = fixture.build_files()["Cargo.lock"]
        edited = fixture.build_files("lock-edit")["Cargo.lock"]
        self.assertNotEqual(baseline, edited)
        self.assertEqual(tomllib.loads(baseline.decode()), tomllib.loads(edited.decode()))
        self.assertIn(b"global freshness probe, no resolution change", edited)

    def test_unknown_variant_rejected(self):
        with self.assertRaises(ValueError):
            fixture.build_files("invented")

    def test_import_and_build_files_have_no_filesystem_io(self):
        source_path = Path(fixture.__file__)
        compiled = compile(source_path.read_bytes(), str(source_path), "exec")
        module = types.ModuleType("fixture_pure_import_test")
        module.__file__ = str(source_path)
        with ExitStack() as guards:
            for target in IO_GUARDS:
                guards.enter_context(patch(target, side_effect=AssertionError("unexpected I/O")))
            exec(compiled, module.__dict__)
            for variant in fixture.VARIANTS:
                self.assertEqual(module.build_files(variant), fixture.build_files(variant))


class DestinationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(
            prefix="g4-qualification-fixture-tests-", dir=fixture.TMP_ROOT
        )
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name)

    def test_materialize_creates_only_fresh_owned_tree_with_exact_bytes(self):
        sentinel = self.parent / "unrelated.txt"
        sentinel.write_bytes(b"unchanged\n")
        for variant in fixture.VARIANTS:
            destination = self.parent / variant
            self.assertEqual(fixture.materialize(destination, variant), destination)
            actual = {
                str(path.relative_to(destination)): path.read_bytes()
                for path in destination.rglob("*") if path.is_file()
            }
            self.assertEqual(actual, fixture.build_files(variant))
            self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
        self.assertEqual(sentinel.read_bytes(), b"unchanged\n")
        self.assertEqual(
            {path.name for path in self.parent.iterdir()}, {*fixture.VARIANTS, "unrelated.txt"}
        )

    def test_existing_directory_file_and_symlink_are_never_reused(self):
        existing_directory = self.parent / "existing-directory"
        existing_directory.mkdir()
        sentinel = existing_directory / "sentinel.txt"
        sentinel.write_bytes(b"keep\n")
        existing_file = self.parent / "existing-file"
        existing_file.write_bytes(b"file\n")
        existing_symlink = self.parent / "existing-symlink"
        existing_symlink.symlink_to(existing_directory, target_is_directory=True)
        for destination in (existing_directory, existing_file, existing_symlink):
            with self.subTest(destination=destination):
                with ExitStack() as guards:
                    for target in ("builtins.open", "io.open", "fixture._create_stage"):
                        guards.enter_context(
                            patch(
                                target, side_effect=AssertionError("existing destination inspected")
                            )
                        )
                    with self.assertRaises(FileExistsError):
                        fixture.materialize(destination)
        self.assertEqual(sentinel.read_bytes(), b"keep\n")
        self.assertEqual(existing_file.read_bytes(), b"file\n")
        self.assertEqual(list(existing_directory.iterdir()), [sentinel])
        self.assertTrue(existing_symlink.is_symlink())

    def test_partial_write_failure_cleans_stage_and_allows_retry(self):
        destination = self.parent / "retry-after-write-failure"
        sentinel = self.parent / "unrelated.txt"
        sentinel.write_bytes(b"keep unrelated bytes\n")
        original_open = os.open
        written_files = []

        def fail_first_library(path, flags, *arguments, **keywords):
            if path == "lib.rs" and flags & os.O_CREAT:
                self.assertEqual(len(written_files), 8)
                self.assertFalse(destination.exists())
                raise OSError(errno.EIO, "injected library source write failure")
            descriptor = original_open(path, flags, *arguments, **keywords)
            if flags & os.O_CREAT:
                written_files.append(path)
            return descriptor

        with patch("fixture.os.open", side_effect=fail_first_library):
            with self.assertRaisesRegex(OSError, "injected library source write failure"):
                fixture.materialize(destination)
        self.assertEqual(len(written_files), 8)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.parent.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b"keep unrelated bytes\n")
        self.assertEqual(fixture.materialize(destination), destination)
        actual = {
            str(path.relative_to(destination)): path.read_bytes()
            for path in destination.rglob("*") if path.is_file()
        }
        self.assertEqual(actual, fixture.build_files())
        self.assertEqual(
            {path.name for path in self.parent.iterdir()}, {destination.name, sentinel.name}
        )

    def test_concurrent_destination_creation_is_not_replaced_or_exchanged(self):
        original_publish = fixture._publish_noreplace
        retained = self.parent / "retained.txt"
        retained.write_bytes(b"keep retained bytes\n")
        expected_entries = {retained.name}
        for kind in ("empty-directory", "nonempty-directory", "file", "symlink"):
            with self.subTest(kind=kind):
                destination = self.parent / f"concurrent-{kind}"
                created_identity = []

                def create_concurrent_destination(parent, stage, name):
                    self.assertEqual(name, destination.name)
                    self.assertFalse(destination.exists())
                    stage_path = self.parent / stage
                    self.assertEqual(
                        (stage_path / "expected-output.txt").read_bytes(),
                        fixture.EXPECTED_STDOUT["baseline"].encode(),
                    )
                    if kind in ("empty-directory", "nonempty-directory"):
                        destination.mkdir()
                        if kind == "nonempty-directory":
                            (destination / "sentinel.txt").write_bytes(b"keep directory bytes\n")
                    elif kind == "file":
                        destination.write_bytes(b"keep destination bytes\n")
                    else:
                        destination.symlink_to(retained)
                    created_identity.append(destination.lstat().st_ino)
                    original_publish(parent, stage, name)

                with patch("fixture._publish_noreplace", side_effect=create_concurrent_destination):
                    with self.assertRaises(FileExistsError):
                        fixture.materialize(destination)
                self.assertEqual(destination.lstat().st_ino, created_identity[0])
                if kind == "empty-directory":
                    self.assertEqual(list(destination.iterdir()), [])
                elif kind == "nonempty-directory":
                    self.assertEqual(
                        (destination / "sentinel.txt").read_bytes(), b"keep directory bytes\n"
                    )
                    self.assertEqual(
                        {path.name for path in destination.iterdir()}, {"sentinel.txt"}
                    )
                elif kind == "file":
                    self.assertEqual(destination.read_bytes(), b"keep destination bytes\n")
                else:
                    self.assertTrue(destination.is_symlink())
                    self.assertEqual(destination.readlink(), retained)
                self.assertEqual(retained.read_bytes(), b"keep retained bytes\n")
                expected_entries.add(destination.name)
                self.assertEqual({path.name for path in self.parent.iterdir()}, expected_entries)

    def test_stage_name_collision_does_not_reuse_or_remove_user_directory(self):
        colliding_bytes = b"a" * 12
        fresh_bytes = b"b" * 12
        existing_stage = self.parent / f".g4-fixture-stage-{colliding_bytes.hex()}"
        existing_stage.mkdir()
        sentinel = existing_stage / "sentinel.txt"
        sentinel.write_bytes(b"keep colliding directory bytes\n")
        destination = self.parent / "collision-safe-fixture"
        with patch("fixture.os.urandom", side_effect=[colliding_bytes, fresh_bytes]):
            fixture.materialize(destination)
        self.assertEqual(sentinel.read_bytes(), b"keep colliding directory bytes\n")
        self.assertEqual(list(existing_stage.iterdir()), [sentinel])
        self.assertEqual(
            {path.name for path in self.parent.iterdir()}, {existing_stage.name, destination.name}
        )
        self.assertEqual(
            (destination / "expected-output.txt").read_bytes(),
            fixture.EXPECTED_STDOUT["baseline"].encode(),
        )

    def test_unavailable_atomic_publication_cleans_stage_without_fallback(self):
        destination = self.parent / "unsupported-publication"
        error = OSError(errno.ENOSYS, "Linux renameat2 is required")
        with patch("fixture.ctypes.CDLL", return_value=object()):
            with self.assertRaisesRegex(OSError, "Linux renameat2 is required"):
                fixture.materialize(destination)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.parent.iterdir()), [])
        with patch("fixture._publish_noreplace", side_effect=error):
            with self.assertRaises(OSError):
                fixture.materialize(destination)
        self.assertFalse(destination.exists())
        self.assertEqual(list(self.parent.iterdir()), [])

    def test_symlink_parents_reject_before_creating_destination(self):
        protected = self.parent / "protected"
        protected.mkdir()
        alias = self.parent / "alias"
        alias.symlink_to(protected, target_is_directory=True)
        with self.assertRaises(OSError):
            fixture.materialize(alias / "fixture")
        self.assertEqual(list(protected.iterdir()), [])
        with patch.object(fixture, "TMP_ROOT", self.parent / "tmp"):
            with patch.object(fixture, "REPOSITORY_ROOT", self.parent):
                (self.parent / "tmp").symlink_to(protected, target_is_directory=True)
                with self.assertRaises(OSError):
                    fixture.materialize(self.parent / "tmp" / "fixture")
        self.assertEqual(list(protected.iterdir()), [])

    def test_missing_parent_is_not_created(self):
        missing = self.parent / "missing"
        with self.assertRaises(FileNotFoundError):
            fixture.materialize(missing / "fixture")
        self.assertFalse(missing.exists())

    def test_unsafe_lexical_paths_reject_before_stat_read_or_mkdir(self):
        unsafe_paths = (
            "", "relative-outside-tmp", "/tmp/outside-fixture",
            fixture.REPOSITORY_ROOT / "outside-tmp",
            fixture.TMP_ROOT, fixture.TMP_ROOT / ".." / "data" / "secrets" / "probe",
            fixture.REPOSITORY_ROOT / "data" / "secrets" / "identity.key",
            fixture.TMP_ROOT / "secrets" / "probe", fixture.TMP_ROOT / "identity.key",
            fixture.TMP_ROOT / "nested" / ".." / "fixture",
            "/other-repository/tmp/fixture",
            str(fixture.TMP_ROOT / "nul") + "\x00",
        )
        with ExitStack() as guards:
            for target in IO_GUARDS:
                guards.enter_context(patch(target, side_effect=AssertionError("unexpected I/O")))
            for destination in unsafe_paths:
                with self.subTest(destination=destination):
                    with self.assertRaises(ValueError):
                        fixture.materialize(destination)

    def test_invalid_variant_does_not_create_destination(self):
        destination = self.parent / "invalid-variant"
        with self.assertRaises(ValueError):
            fixture.materialize(destination, "invented")
        self.assertFalse(destination.exists())

    def test_cli_requires_explicit_output_and_valid_variant(self):
        invalid_arguments = (
            [], ["--variant", "baseline"], ["--output", "unused", "--variant", "bad"],
        )
        for arguments in invalid_arguments:
            with self.subTest(arguments=arguments):
                with redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as error:
                        fixture.main(arguments)
                self.assertEqual(error.exception.code, 2)

    def test_cli_materializes_requested_variant_and_prints_owned_path(self):
        destination = self.parent / "cli-rust-edit"
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            status = fixture.main(["--output", str(destination), "--variant", "rust-edit"])
        self.assertEqual(status, 0)
        self.assertEqual(stdout.getvalue(), f"{destination}\n")
        self.assertEqual(
            (destination / "expected-output.txt").read_bytes(),
            fixture.EXPECTED_STDOUT["rust-edit"].encode(),
        )


if __name__ == "__main__":
    unittest.main()
