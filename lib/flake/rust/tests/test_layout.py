"""Source-only layout regressions; never import or execute the candidate tools."""

import ast
from pathlib import Path
import re
import unittest


RUST = Path(__file__).resolve().parents[1]
ROOT = RUST.parents[2]
QUALIFICATION = RUST / "qualification"
MIRROR = RUST / "mirror"


def source_tree(path):
    return ast.parse(path.read_bytes(), filename=str(path))


def assignment(tree, name):
    return next(node.value for node in tree.body if isinstance(node, ast.Assign)
                and any(isinstance(target, ast.Name) and target.id == name
                        for target in node.targets))


class LayoutTests(unittest.TestCase):
    def test_fixture_checkout_root_ancestor(self):
        value = assignment(source_tree(QUALIFICATION / "fixture.py"), "REPOSITORY_ROOT")
        self.assertEqual(ast.unparse(value), "Path(__file__).absolute().parents[4]")
        self.assertEqual((QUALIFICATION / "fixture.py").parents[4], ROOT)

    def test_mirror_loader_and_cli_point_to_moved_generator(self):
        path = MIRROR / "tests/test_rust_mirror.py"
        tree = source_tree(path)
        self.assertEqual(ast.unparse(assignment(tree, "ROOT")),
                         "Path(__file__).resolve().parents[5]")
        self.assertEqual(path.parents[5], ROOT)
        strings = [node.value for node in ast.walk(tree)
                   if isinstance(node, ast.Constant) and isinstance(node.value, str)]
        self.assertEqual(strings.count("lib/flake/rust/mirror/rust-mirror.py"), 2)
        self.assertNotIn("scripts/support/rust-mirror.py", strings)
        self.assertTrue((MIRROR / "rust-mirror.py").is_file())

    def test_generator_with_name_validator_stays_adjacent(self):
        tree = source_tree(MIRROR / "rust-mirror.py")
        validators = [node.args[0].value for node in ast.walk(tree)
                      if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                      and node.func.attr == "with_name" and node.args
                      and isinstance(node.args[0], ast.Constant)]
        self.assertIn("rust-mirror-validate.nix", validators)
        self.assertTrue((MIRROR / "rust-mirror-validate.nix").is_file())

    def test_nix_repository_imports_keep_same_owner(self):
        count = 0
        for path in sorted(QUALIFICATION.glob("*.nix")):
            text = path.read_text()
            self.assertNotIn("import ../../../lib/", text)
            for relative in re.findall(r"\bimport (\.\./[^\s;{]+)", text):
                self.assertTrue(relative.startswith("../"), (path, relative))
                self.assertTrue((path.parent / relative).is_file(), (path, relative))
                count += 1
        self.assertGreaterEqual(count, 3)

    def test_repository_scenarios_are_outside_the_generic_library(self):
        owner = ROOT / "scripts/qualification/rust"
        for name in ("manager-recipes.nix", "manager-vm.nix",
                     "manager-patched-vm.nix", "product-eval.nix"):
            self.assertTrue((owner / "pvl" / name).is_file())
            self.assertFalse((QUALIFICATION / name).exists())
        self.assertTrue((owner / "abird/recipes.nix").is_file())
        self.assertFalse((QUALIFICATION / "abird-recipes.nix").exists())
        for path in QUALIFICATION.glob("*.nix"):
            text = path.read_text()
            self.assertNotIn("scripts/qualification", text, path)
            self.assertNotIn("pkgs/tools/abird-", text, path)
            self.assertNotIn("pkgs/support/nats-", text, path)

    def test_python_sibling_imports_still_resolve(self):
        siblings = {path.stem for path in QUALIFICATION.glob("*.py")}
        for path in sorted(QUALIFICATION.glob("*.py")):
            for node in ast.walk(source_tree(path)):
                if isinstance(node, ast.Import):
                    for alias in node.names:
                        if alias.name in {"fixture", "freshness", "product_semantic",
                                          "store_metadata", "prerequisite_batches"}:
                            self.assertIn(alias.name, siblings, path)

    def test_freshness_requires_explicit_discovery(self):
        standard = {path.name for path in QUALIFICATION.glob("test_*.py")}
        explicit = {path.name for path in QUALIFICATION.glob("freshness*test.py")}
        self.assertNotIn("freshness_test.py", standard)
        self.assertIn("freshness_test.py", explicit)
        tree = source_tree(QUALIFICATION / "freshness_test.py")
        self.assertTrue(any(isinstance(node, ast.FunctionDef) and node.name.startswith("test_")
                            for node in ast.walk(tree)))

    def test_language_implementations_have_canonical_owners(self):
        for language in ("rust", "go", "nodejs", "python", "shell"):
            self.assertTrue((ROOT / "lib/flake" / language / "default.nix").is_file())
        self.assertEqual(list((ROOT / "lib/flake").glob("rust-*.nix")), [])
        self.assertFalse((ROOT / "lib/flake/member-bases.nix").exists())
        self.assertFalse((ROOT / "lib/flake/trunk").exists())
        self.assertTrue((RUST / "trunk/write-wasm-bootstrap.sh").is_file())
        self.assertTrue((RUST / "tests/default.nix").is_file())

    def test_old_active_entries_are_absent(self):
        for path in (ROOT / "scripts/rust-fabric", ROOT / "scripts/rust-g4-qualification", ROOT / "scripts/rust-unit-spike",
                     ROOT / "scripts/support/rust-mirror.py",
                     ROOT / "scripts/support/rust-mirror-validate.nix",
                     ROOT / "scripts/support/tests/test_rust_mirror.py"):
            self.assertFalse(path.exists(), path)


if __name__ == "__main__":
    unittest.main()
