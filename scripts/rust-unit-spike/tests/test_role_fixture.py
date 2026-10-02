"""Read-only fixture checks, not compilation evidence or exact-unit proof."""

from pathlib import Path
import unittest

try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None


FIXTURE = Path(__file__).parent / "fixtures" / "unit-roles"
PACKAGES = (
    "role-app",
    "role-shared",
    "role-build-helper",
    "role-macro",
    "role-dev-helper",
)
DEPENDENCY_KINDS = ("dependencies", "build-dependencies", "dev-dependencies")


@unittest.skipIf(tomllib is None, "stdlib tomllib requires Python 3.11 or newer")
class RoleFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Only these seven known TOML/lock files are opened, all read-only.
        def load(path):
            with path.open("rb") as stream:
                return tomllib.load(stream)

        cls.root = load(FIXTURE / "Cargo.toml")
        cls.manifests = {
            name: load(FIXTURE / name / "Cargo.toml") for name in PACKAGES
        }
        cls.lock = load(FIXTURE / "Cargo.lock")

    def test_resolver_and_default_root(self):
        self.assertEqual(set(self.root), {"workspace"})
        workspace = self.root["workspace"]
        self.assertEqual(set(workspace), {"resolver", "members", "default-members"})
        self.assertEqual(workspace["resolver"], "2")
        self.assertEqual(workspace["default-members"], ["role-app"])
        self.assertCountEqual(workspace["members"], PACKAGES)

    def test_exactly_five_local_packages(self):
        expected_paths = {FIXTURE / name / "Cargo.toml" for name in PACKAGES}
        expected_paths.add(FIXTURE / "Cargo.toml")
        self.assertEqual(set(FIXTURE.rglob("Cargo.toml")), expected_paths)
        self.assertEqual(len(self.manifests), 5)
        for name, manifest in self.manifests.items():
            with self.subTest(package=name):
                package = manifest["package"]
                self.assertEqual(package["name"], name)
                self.assertEqual(package["version"], "0.1.0")
                self.assertEqual(package["edition"], "2021")
                self.assertIs(package["publish"], False)
                self.assertLessEqual(
                    set(package), {"name", "version", "edition", "publish", "build"}
                )

    def test_no_external_dependencies_or_fetch_configuration(self):
        # Inspect names only; never open configuration or unrelated files.
        self.assertEqual(list(FIXTURE.rglob(".cargo")), [])
        allowed_sections = {"package", "features", "lib", *DEPENDENCY_KINDS}
        for name, manifest in self.manifests.items():
            with self.subTest(package=name):
                # Reject patch/replace, workspace inheritance, target-specific
                # hidden dependencies, and other undeclared fixture sections.
                self.assertLessEqual(set(manifest), allowed_sections)
                for kind in DEPENDENCY_KINDS:
                    for dependency, spec in manifest.get(kind, {}).items():
                        with self.subTest(kind=kind, dependency=dependency):
                            self.assertIn(dependency, PACKAGES)
                            self.assertIsInstance(spec, dict)
                            self.assertLessEqual(
                                set(spec), {"path", "features", "default-features"}
                            )
                            self.assertEqual(spec["path"], f"../{dependency}")
                            self.assertEqual(
                                (FIXTURE / name / spec["path"]).resolve(),
                                (FIXTURE / dependency).resolve(),
                            )

    def test_declared_normal_build_and_dev_edges(self):
        expected = {
            "role-app": {
                "dependencies": {"role-shared", "role-macro"},
                "build-dependencies": {"role-build-helper"},
                "dev-dependencies": {"role-dev-helper"},
            },
            "role-shared": {},
            "role-build-helper": {"dependencies": {"role-shared"}},
            "role-macro": {"dependencies": {"role-shared"}},
            "role-dev-helper": {"dependencies": {"role-shared"}},
        }
        for name, manifest in self.manifests.items():
            for kind in DEPENDENCY_KINDS:
                with self.subTest(package=name, kind=kind):
                    self.assertEqual(
                        set(manifest.get(kind, {})), expected[name].get(kind, set())
                    )

    def test_lock_matches_manifest_dependency_union(self):
        self.assertEqual(set(self.lock), {"version", "package"})
        self.assertEqual(self.lock["version"], 4)
        entries = self.lock["package"]
        self.assertEqual(len(entries), 5)
        self.assertCountEqual([entry["name"] for entry in entries], PACKAGES)
        for entry in entries:
            name = entry["name"]
            with self.subTest(package=name):
                self.assertLessEqual(set(entry), {"name", "version", "dependencies"})
                self.assertEqual(entry["version"], self.manifests[name]["package"]["version"])
                dependencies = {
                    dependency
                    for kind in DEPENDENCY_KINDS
                    for dependency in self.manifests[name].get(kind, {})
                }
                # Cargo.lock records the union, not the normal/build/dev kinds.
                self.assertCountEqual(entry.get("dependencies", []), dependencies)

    def test_proc_macro_and_build_script_declarations(self):
        self.assertEqual(self.manifests["role-macro"]["lib"], {"proc-macro": True})
        self.assertEqual(self.manifests["role-app"]["package"]["build"], "build.rs")
        for name in PACKAGES:
            if name != "role-macro":
                self.assertNotIn("lib", self.manifests[name])
            if name != "role-app":
                self.assertNotIn("build", self.manifests[name]["package"])

    def test_separate_explicit_shared_feature_labels(self):
        self.assertEqual(
            self.manifests["role-shared"]["features"],
            {
                "default": [],
                "target-only": [],
                "host-build": [],
                "host-macro": [],
                "dev-only": [],
            },
        )
        consumers = {
            "role-app": "target-only",
            "role-build-helper": "host-build",
            "role-macro": "host-macro",
            "role-dev-helper": "dev-only",
        }
        for name, feature in consumers.items():
            with self.subTest(package=name, feature=feature):
                self.assertNotIn("features", self.manifests[name])
                spec = self.manifests[name]["dependencies"]["role-shared"]
                self.assertEqual(spec["features"], [feature])
                self.assertIs(spec["default-features"], False)


if __name__ == "__main__":
    unittest.main()
