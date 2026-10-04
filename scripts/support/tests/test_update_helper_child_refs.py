import contextlib
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "scripts/support/update-helper.py"
TEST_TMP = REPO_ROOT / "tmp/helper-consolidation"
TEST_TMP.mkdir(parents=True, exist_ok=True)
spec = importlib.util.spec_from_file_location("update_helper_child_refs", SCRIPT)
pins = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pins)

SOURCES = {
    "nixpkgs": {"owner": "nixos", "repo": "nixpkgs", "ref": "nixos-26.05"},
    "crane": {"owner": "ipetkov", "repo": "crane", "ref": "v0.24.0"},
    "flake-utils": {"owner": "numtide", "repo": "flake-utils"},
}
URLS = {
    "nixpkgs": "github:nixos/nixpkgs/nixos-26.05",
    "crane": "github:ipetkov/crane/v0.24.0",
    "flake-utils": "github:numtide/flake-utils",
}
WRAPPER = '''{
  inputs = {
    nixpkgs.url = "old";
    flake-utils.url = "old";
  };
  outputs = inputs:
    (import ../../lib/flake/stack/package.nix).mkFlakeOutputs ./default.nix inputs;
}
'''
WRAPPER_WITH_CRANE = WRAPPER.replace(
    "  inputs = {", '  inputs = {\n    crane.url = "old";'
)


UNSUPPORTED_CRANE_DECLARATIONS = (
    'crane = { url = "old"; };',
    '"crane".url = "old";',
    '"crane" = { url = "old"; };',
    'crane."url" = "old";',
    'inherit crane;',
    'inherit (upstream) crane;',
    '${inputName}.url = "old";',
)


def root_lock():
    nodes = {
        name + "_selected": {
            "original": {"type": "github", **source},
            "locked": {
                "type": "github", "owner": source["owner"], "repo": source["repo"],
                "rev": "a" * 40, "narHash": "sha256-fixture",
            },
        }
        for name, source in SOURCES.items()
    }
    nodes["entry"] = {"inputs": {name: name + "_selected" for name in pins.INPUTS}}
    # Trap nodes must never be selected just because their names match inputs.
    nodes.update({name: {"locked": {"rev": "wrong"}} for name in pins.INPUTS})
    return {"root": "entry", "nodes": nodes, "version": 7}


class RootRefsTests(unittest.TestCase):
    def urls(self, lock):
        with patch.object(Path, "read_text", return_value=json.dumps(lock)):
            return pins.root_urls(Path("unused"))

    def test_duplicate_json_keys_fail_closed(self):
        with patch.object(Path, "read_text", return_value='{"nodes": {}, "nodes": {}}'):
            with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
                pins.root_urls(Path("unused"))

    def test_root_input_edges_not_first_matching_node(self):
        self.assertEqual(self.urls(root_lock()), URLS)

    def test_all_input_nodes_can_be_remapped(self):
        lock = root_lock()
        for index, name in enumerate(pins.INPUTS):
            key = f"arbitrary_{index}"
            lock["nodes"][key] = lock["nodes"].pop(name + "_selected")
            lock["nodes"]["entry"]["inputs"][name] = key
        self.assertEqual(self.urls(lock), URLS)

    def test_compatibility_api_preserves_original_refs(self):
        with patch.object(Path, "read_text", return_value=json.dumps(root_lock())):
            self.assertEqual(pins.locked_urls(Path("unused")), URLS)

    def test_crane_requires_version_tag(self):
        for ref in (None, "master", "latest", "v0.24", "0.24.0", "a" * 40):
            with self.subTest(ref=ref):
                lock = root_lock()
                original = lock["nodes"]["crane_selected"]["original"]
                original.pop("ref")
                if ref is not None:
                    original["ref"] = ref
                with self.assertRaisesRegex(ValueError, "crane original.*version tag"):
                    self.urls(lock)

    def test_nixpkgs_requires_release_branch(self):
        for ref in (
            None, "nixos-unstable", "nixos-26.x", "26.x", "a" * 40,
            "nixos-27.01", "nixos-2027.05", "nixos-7.11",
        ):
            with self.subTest(ref=ref):
                lock = root_lock()
                lock["nodes"]["nixpkgs_selected"]["original"]["ref"] = ref
                with self.assertRaisesRegex(ValueError, "nixpkgs original.*release branch"):
                    self.urls(lock)

    def test_version_tag_and_next_26_release_branch(self):
        lock = root_lock()
        lock["nodes"]["crane_selected"]["original"]["ref"] = "v1.2.3"
        lock["nodes"]["nixpkgs_selected"]["original"]["ref"] = "nixos-26.11"
        urls = self.urls(lock)
        self.assertTrue(urls["crane"].endswith("/v1.2.3"))
        self.assertTrue(urls["nixpkgs"].endswith("/nixos-26.11"))

    def test_release_year_is_not_hardcoded(self):
        for ref in ("nixos-25.11", "nixos-27.05", "nixos-28.11"):
            with self.subTest(ref=ref):
                lock = root_lock()
                lock["nodes"]["nixpkgs_selected"]["original"]["ref"] = ref
                self.assertEqual(self.urls(lock)["nixpkgs"], f"github:nixos/nixpkgs/{ref}")

    def test_original_revision_rejected_even_alongside_ref(self):
        for name in ("crane", "nixpkgs"):
            with self.subTest(name=name):
                lock = root_lock()
                lock["nodes"][name + "_selected"]["original"]["rev"] = "a" * 40
                with self.assertRaisesRegex(ValueError, "original must use"):
                    self.urls(lock)

    def test_provenance_requires_matching_github_sources(self):
        for name in pins.INPUTS:
            for field, value in (("type", "git"), ("owner", "someone"), ("repo", "else")):
                with self.subTest(name=name, field=field):
                    lock = root_lock()
                    lock["nodes"][name + "_selected"]["locked"][field] = value
                    with self.assertRaisesRegex(ValueError, "github|provenance mismatch"):
                        self.urls(lock)

    def test_policy_sources_cannot_be_replaced_with_matching_forks(self):
        for name in ("crane", "nixpkgs"):
            lock = root_lock()
            for section in ("original", "locked"):
                lock["nodes"][name + "_selected"][section]["owner"] = "someone"
            with self.assertRaisesRegex(ValueError, "unexpected.*GitHub source"):
                self.urls(lock)

    def test_missing_lock_sections_fail_closed(self):
        for section in ("original", "locked"):
            lock = root_lock()
            del lock["nodes"]["crane_selected"][section]
            with self.assertRaisesRegex(ValueError, "malformed root input lock"):
                self.urls(lock)

    def test_follow_edge_not_accepted_as_direct_locked_node(self):
        lock = root_lock()
        lock["nodes"]["entry"]["inputs"]["nixpkgs"] = ["another", "nixpkgs"]
        with self.assertRaisesRegex(ValueError, "must have a locked node"):
            self.urls(lock)

    def test_locked_revision_and_hash_required(self):
        for field, value in (("rev", "short"), ("rev", None), ("narHash", "")):
            lock = root_lock()
            lock["nodes"]["crane_selected"]["locked"][field] = value
            with self.assertRaisesRegex(ValueError, "exact locked revision|locked narHash"):
                self.urls(lock)

    def test_flake_utils_uses_original_default_or_explicit_ref(self):
        lock = root_lock()
        self.assertEqual(self.urls(lock)["flake-utils"], "github:numtide/flake-utils")
        lock["nodes"]["flake-utils_selected"]["original"]["ref"] = "some-release"
        self.assertEqual(self.urls(lock)["flake-utils"], "github:numtide/flake-utils/some-release")

    def test_flake_utils_original_explicit_revision_requires_matching_lock(self):
        lock = root_lock()
        node = lock["nodes"]["flake-utils_selected"]
        node["original"]["rev"] = "a" * 40
        self.assertEqual(self.urls(lock)["flake-utils"], "github:numtide/flake-utils/" + "a" * 40)
        node["locked"]["rev"] = "b" * 40
        with self.assertRaisesRegex(ValueError, "revision mismatch"):
            self.urls(lock)


class WrapperUpdateTests(unittest.TestCase):
    def test_retains_declared_crane_wrapper_and_idempotent(self):
        updated = pins.update_wrapper(WRAPPER_WITH_CRANE, URLS)
        self.assertIn("mkFlakeOutputs ./default.nix inputs;", updated)
        for name, url in URLS.items():
            self.assertIn(f'{name}.url = "{url}";', updated)
        self.assertEqual(pins.update_wrapper(updated, URLS), updated)

    def test_no_crane_wrapper_remains_no_crane_and_idempotent(self):
        updated = pins.update_wrapper(WRAPPER, URLS)
        self.assertNotIn("crane", updated)
        for name in ("nixpkgs", "flake-utils"):
            self.assertIn(f'{name}.url = "{URLS[name]}";', updated)
        self.assertEqual(pins.update_wrapper(updated, URLS), updated)

    def test_declared_crane_tracks_changed_version_tag(self):
        urls = {**URLS, "crane": "github:ipetkov/crane/v1.2.3"}
        updated = pins.update_wrapper(WRAPPER_WITH_CRANE, urls)
        self.assertIn('crane.url = "github:ipetkov/crane/v1.2.3";', updated)
        self.assertEqual(pins.update_wrapper(updated, urls), updated)

    def test_format_varied_url_assignments(self):
        wrapper = '''{ inputs\n=\n{ nixpkgs /* keep */ . url= "old" ;
flake-utils\n.\nurl = "old"; crane.url="old"; }; outputs = keep; }'''
        updated = pins.update_wrapper(wrapper, URLS)
        self.assertIn("/* keep */", updated)
        self.assertIn("outputs = keep;", updated)
        for url in URLS.values():
            self.assertIn(f'"{url}"', updated)
        self.assertEqual(pins.update_wrapper(updated, URLS), updated)

    def test_comments_and_strings_are_not_assignments(self):
        wrapper = WRAPPER.replace("{\n", '''{
  # nixpkgs.url = "not an input";
  description = "crane.url = fake;";
  note = ''flake-utils.url = "fake";'';
''', 1).replace("  inputs = {", '''  inputs = {
    # crane.url = "fake";
    /* crane = { url = "fake"; }; */
    other.note = "crane.url = fake;";''')
        updated = pins.update_wrapper(wrapper, URLS)
        self.assertIn('# nixpkgs.url = "not an input";', updated)
        self.assertIn('description = "crane.url = fake;";', updated)
        self.assertIn('# crane.url = "fake";', updated)
        self.assertIn('/* crane = { url = "fake"; }; */', updated)
        self.assertNotIn(URLS["crane"], updated)

    def test_missing_required_input_fails_closed(self):
        for name in ("nixpkgs", "flake-utils"):
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, f"missing {name}"):
                pins.update_wrapper(WRAPPER.replace(f'{name}.url = "old";', ""), URLS)

    def test_missing_inputs_block_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "unique child inputs block"):
            pins.update_wrapper("{}", URLS)

    def test_unsupported_crane_declarations_fail_instead_of_being_ignored(self):
        for declaration in UNSUPPORTED_CRANE_DECLARATIONS:
            with self.subTest(declaration=declaration):
                wrapper = WRAPPER.replace("  inputs = {", f"  inputs = {{\n    {declaration}")
                with self.assertRaisesRegex(ValueError, "unsupported.*input declaration"):
                    pins.update_wrapper(wrapper, URLS)

    def test_supported_plus_unsupported_definitions_fail_closed(self):
        for name in URLS:
            with self.subTest(name=name):
                wrapper = WRAPPER.replace(
                    "  inputs = {", f'  inputs = {{\n    {name} = {{ url = "other"; }};'
                )
                # Crane normally is absent in this fixture; supply its dot URL
                # too to ensure grouped syntax is rejected even when found.
                if name == "crane":
                    wrapper = wrapper.replace("  inputs = {", '  inputs = { crane.url = "old";')
                with self.assertRaisesRegex(ValueError, f"unsupported {name} input"):
                    pins.update_wrapper(wrapper, URLS)

    def test_other_managed_inputs_also_reject_unsupported_syntax(self):
        for name in ("nixpkgs", "flake-utils"):
            for declaration in (f'{name} = {{ url = "old"; }};', f'inherit {name};'):
                with self.subTest(declaration=declaration):
                    wrapper = WRAPPER.replace(f'{name}.url = "old";', declaration)
                    with self.assertRaisesRegex(ValueError, "unsupported.*input declaration"):
                        pins.update_wrapper(wrapper, URLS)

    def test_unrelated_code_outside_inputs_block_is_unchanged(self):
        unrelated = 'let crane = { url = "unrelated"; }; nixpkgs.url = "unrelated"; in'
        wrapper = WRAPPER.replace("  outputs = inputs:", f"  outputs = inputs: {unrelated}")
        updated = pins.update_wrapper(wrapper, URLS)
        self.assertIn(unrelated, updated)
        self.assertNotIn("crane.url", updated)
        self.assertEqual(pins.update_wrapper(updated, URLS), updated)

    def test_nested_other_input_url_is_not_a_root_crane_declaration(self):
        for nested in (
            'other = { inputs.crane.url = "unrelated"; };',
            'other = { crane = { url = "unrelated"; }; };',
        ):
            with self.subTest(nested=nested):
                wrapper = WRAPPER.replace("  inputs = {", f"  inputs = {{ {nested}")
                updated = pins.update_wrapper(wrapper, URLS)
                self.assertIn(nested, updated)
                self.assertNotIn(URLS["crane"], updated)
                self.assertEqual(pins.update_wrapper(updated, URLS), updated)

    def test_duplicate_input_fails_closed(self):
        for name in URLS:
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, f"ambiguous {name}"):
                pins.update_wrapper(WRAPPER_WITH_CRANE.replace(
                    f'{name}.url = "old";', f'{name}.url="old"; {name}.url="old";'
                ), URLS)

    def test_nonliteral_input_fails_closed(self):
        for name in URLS:
            for value in ("computed", '"${computed}"', "''computed''"):
                with self.subTest(name=name, value=value), \
                        self.assertRaisesRegex(ValueError, "literal URL"):
                    pins.update_wrapper(WRAPPER_WITH_CRANE.replace(
                        f'{name}.url = "old";', f"{name}.url = {value};"
                    ), URLS)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        # Disposable fixtures remain inside the task checkout, never /tmp.
        self.temp = tempfile.TemporaryDirectory(dir=TEST_TMP)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "pkgs/pilot").mkdir(parents=True)
        (self.root / "flake.lock").write_text(json.dumps(root_lock()))
        self.wrapper = self.root / "pkgs/pilot/flake.nix"
        self.wrapper.write_text(WRAPPER)

    def test_discovery_requires_no_json_inventory(self):
        self.assertEqual(list((self.root / "pkgs").rglob("*.json")), [])
        self.assertEqual(pins.discover_wrappers(self.root), [self.wrapper])

    def test_new_wrapper_is_automatically_included_and_updated(self):
        new = self.root / "pkgs/new/nested/flake.nix"
        new.parent.mkdir(parents=True)
        new.write_text(WRAPPER.replace("../../lib/flake", "../../../lib/flake"))
        self.assertEqual(pins.discover_wrappers(self.root), [new, self.wrapper])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 0)
        for path in (new, self.wrapper):
            for name in ("nixpkgs", "flake-utils"):
                self.assertIn(f'{name}.url = "{URLS[name]}";', path.read_text())
            self.assertNotIn("crane", path.read_text())

    def test_generated_trees_at_source_boundaries_are_not_walked_or_touched(self):
        ignored_flakes = []
        generated_trees = []
        for index, marker in enumerate(("default.nix", "Cargo.toml", "package.json")):
            source = self.wrapper.parent / f"source-{index}"
            source.mkdir()
            (source / marker).write_text("source boundary fixture\n")
            for name in ("node_modules", "target", "dist", ".direnv"):
                generated = source / name
                vendor = generated / "vendor/flake.nix"
                vendor.parent.mkdir(parents=True)
                library = os.path.relpath(self.root / "lib/flake", vendor.parent)
                vendor.write_text(WRAPPER.replace("../../lib/flake", library).replace(
                    'nixpkgs.url = "old";', ""
                ))
                self.assertTrue(pins.uses_repository_helper(vendor, self.root))
                # Traversing this tree would also encounter an unsafe alias.
                (generated / "escape").symlink_to(self.root, target_is_directory=True)
                ignored_flakes.append(vendor)
                generated_trees.append(generated)
        before = {path: path.read_bytes() for path in ignored_flakes}
        visited = []
        actual_walk = os.walk

        def tracked_walk(*args, **kwargs):
            for entry in actual_walk(*args, **kwargs):
                visited.append(Path(entry[0]))
                yield entry

        with patch.object(pins.os, "walk", side_effect=tracked_walk), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 0)
        for generated in generated_trees:
            self.assertFalse(any(path.is_relative_to(generated) for path in visited))
        for path, original in before.items():
            self.assertEqual(path.read_bytes(), original)
        self.assertIn(URLS["nixpkgs"], self.wrapper.read_text())
        self.assertNotIn("crane", self.wrapper.read_text())

    def test_generated_symlinks_at_source_boundaries_are_ignored(self):
        outside = self.root / "outside"
        outside.mkdir()
        external = outside / "flake.nix"
        external.write_text(WRAPPER.replace("../../lib/flake", "../lib/flake"))
        before = external.read_bytes()
        links = {}
        for index, marker in enumerate(("default.nix", "Cargo.toml", "package.json")):
            source = self.wrapper.parent / f"source-{index}"
            source.mkdir()
            (source / marker).write_text("source boundary fixture\n")
            targets = (outside, self.wrapper.parent, source / "missing", source / ".direnv")
            for name, target in zip(("node_modules", "target", "dist", ".direnv"), targets):
                link = source / name
                link.symlink_to(target, target_is_directory=True)
                links[link] = link.readlink()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pins.discover_wrappers(self.root), [self.wrapper])
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 0)
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--check"]), 0)
        self.assertEqual(external.read_bytes(), before)
        for link, target in links.items():
            self.assertTrue(link.is_symlink())
            self.assertEqual(link.readlink(), target)

    def test_git_trees_and_symlinks_are_ignored_without_source_markers(self):
        ignored_flakes = []
        for parent in (self.root / "pkgs", self.root / "pkgs/group", self.wrapper.parent):
            git = parent / ".git"
            git.mkdir(parents=True)
            flake = git / "flake.nix"
            library = os.path.relpath(self.root / "lib/flake", git)
            flake.write_text(WRAPPER.replace("../../lib/flake", library))
            (git / "escape").symlink_to(self.root, target_is_directory=True)
            ignored_flakes.append(flake)
        aliases = self.root / "pkgs/aliases"
        aliases.mkdir()
        (aliases / ".git").symlink_to(self.root, target_is_directory=True)
        broken = self.root / "pkgs/broken"
        broken.mkdir()
        (broken / ".git").symlink_to(broken / "missing", target_is_directory=True)
        before = {path: path.read_bytes() for path in ignored_flakes}
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pins.discover_wrappers(self.root), [self.wrapper])
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 0)
        for path, original in before.items():
            self.assertEqual(path.read_bytes(), original)
        self.assertTrue((aliases / ".git").is_symlink())
        self.assertTrue((broken / ".git").is_symlink())

    def test_real_packages_named_like_generated_trees_are_discovered(self):
        real_packages = []
        for name in ("target", "dist", "node_modules", ".direnv"):
            flake = self.root / "pkgs/tools" / name / "flake.nix"
            flake.parent.mkdir(parents=True)
            (flake.parent / "default.nix").write_text("package fixture\n")
            flake.write_text(WRAPPER_WITH_CRANE.replace("../../lib/flake", "../../../lib/flake"))
            real_packages.append(flake)
        self.assertEqual(pins.discover_wrappers(self.root), sorted([self.wrapper, *real_packages]))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 0)
        for path in real_packages:
            self.assertIn(URLS["crane"], path.read_text())

    def test_generated_names_without_source_boundary_do_not_allow_symlink_aliases(self):
        group = self.root / "pkgs/tools"
        group.mkdir()
        for name in ("node_modules", "target", "dist", ".direnv"):
            with self.subTest(name=name):
                link = group / name
                link.symlink_to(self.wrapper.parent, target_is_directory=True)
                before = self.wrapper.read_bytes()
                with contextlib.redirect_stdout(io.StringIO()), \
                        contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 2)
                self.assertEqual(self.wrapper.read_bytes(), before)
                link.unlink()

    def test_deleted_last_wrapper_fails_closed(self):
        self.wrapper.unlink()
        with self.assertRaisesRegex(ValueError, "no repository-bound child wrappers"):
            pins.discover_wrappers(self.root)

    def test_empty_discovery_fails_in_both_cli_modes(self):
        self.wrapper.write_text('{ outputs = inputs: {}; }')
        for mode in ("--check", "--write"):
            with self.subTest(mode=mode):
                stdout, stderr = io.StringIO(), io.StringIO()
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    self.assertEqual(pins.main(["child-refs", "--root", str(self.root), mode]), 2)
                self.assertIn("no repository-bound child wrappers", stderr.getvalue())
                self.assertEqual(stdout.getvalue(), "")

    def test_missing_pkgs_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "missing or unsafe child package directory"):
            pins.discover_wrappers(self.root / "missing")

    def test_arbitrary_whitespace_and_aliased_helper_discovery(self):
        self.wrapper.write_text('''{
outputs = inputs: let
  helper = import /* varied */
    ../../lib/flake/stack/package.nix;
in helper
 . mkFlakeOutputs ./default.nix inputs;
}''')
        self.assertEqual(pins.discover_wrappers(self.root), [self.wrapper])

    def test_discovery_does_not_depend_on_specific_helper_names(self):
        for helper in ("stack/package.nix", "pkg-helper.nix", "future/adapter.nix", "default.nix"):
            with self.subTest(helper=helper):
                self.wrapper.write_text(f'''{{ outputs = inputs:
let adapter = import ../../lib/flake/{helper};
in adapter {{ packageName = "pilot"; inputs = inputs; }}; }}''')
                self.assertEqual(pins.discover_wrappers(self.root), [self.wrapper])

    def test_comments_and_strings_do_not_discover_external_flakes(self):
        external = self.root / "pkgs/external/flake.nix"
        external.parent.mkdir()
        external.write_text('''{
# import ../../lib/flake/stack/package.nix
/* import ../../lib/flake/stack/package.nix */
description = "../../lib/flake/stack/package.nix";
note = ''../../lib/flake/stack/package.nix'';
outputs = inputs: {};
}''')
        self.assertEqual(pins.discover_wrappers(self.root), [self.wrapper])
        before = external.read_text()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 0)
        self.assertEqual(external.read_text(), before)

    def test_independent_external_flake_and_lock_are_untouched(self):
        external = self.root / "pkgs/external/flake.nix"
        external.parent.mkdir()
        external.write_text(WRAPPER.replace("../../lib/flake/stack/package.nix", "./helper.nix"))
        child_lock = self.wrapper.with_name("flake.lock")
        child_lock.write_text("independent lock state\n")
        before = {path: path.read_bytes() for path in (external, child_lock)}
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 0)
        for path, original in before.items():
            self.assertEqual(path.read_bytes(), original)

    def test_symlink_flakes_fail_before_any_write(self):
        outside = self.root / "outside.nix"
        outside.write_text(WRAPPER)
        alias = self.root / "pkgs/z-alias/flake.nix"
        alias.parent.mkdir()
        for target in (outside, self.wrapper, self.root / "missing.nix"):
            with self.subTest(target=target):
                alias.symlink_to(target)
                before = self.wrapper.read_bytes(), outside.read_bytes()
                with contextlib.redirect_stdout(io.StringIO()), \
                        contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 2)
                self.assertEqual((self.wrapper.read_bytes(), outside.read_bytes()), before)
                alias.unlink()

    def test_symlink_directories_fail_instead_of_hiding_wrappers(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "flake.nix").write_text(WRAPPER)
        alias = self.root / "pkgs/z-alias"
        for target in (outside, self.wrapper.parent, self.root / "pkgs", alias, outside / "missing"):
            with self.subTest(target=target):
                alias.symlink_to(target, target_is_directory=True)
                before = self.wrapper.read_bytes()
                with contextlib.redirect_stdout(io.StringIO()), \
                        contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 2)
                self.assertEqual(self.wrapper.read_bytes(), before)
                alias.unlink()

    def test_symlink_package_root_fails_closed(self):
        packages = self.root / "pkgs"
        packages.rename(self.root / "real-packages")
        packages.symlink_to(self.root / "real-packages", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "unsafe child package directory"):
            pins.discover_wrappers(self.root)

    def test_non_file_flake_fails_closed(self):
        self.wrapper.unlink()
        self.wrapper.mkdir()
        with self.assertRaisesRegex(ValueError, "unsafe child wrapper"):
            pins.discover_wrappers(self.root)

    def test_non_child_package_root_flake_fails_closed(self):
        (self.root / "pkgs/flake.nix").write_text(
            WRAPPER.replace("../../lib/flake", "../lib/flake")
        )
        with self.assertRaisesRegex(ValueError, "invalid child wrapper path"):
            pins.discover_wrappers(self.root)

    def test_similarly_named_library_is_not_repository_helper(self):
        self.wrapper.write_text(WRAPPER.replace("lib/flake/", "lib/flake-independent/"))
        with self.assertRaisesRegex(ValueError, "no repository-bound child wrappers"):
            pins.discover_wrappers(self.root)

    def test_no_crane_check_write_check_cycle_is_idempotent(self):
        # Source-language markers must never imply a Crane dependency.
        (self.wrapper.parent / "Cargo.toml").write_text("source fixture\n")
        before = self.wrapper.read_text()
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--check"]), 1)
            self.assertEqual(self.wrapper.read_text(), before)
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 0)
            self.assertNotIn("crane", self.wrapper.read_text())
            updated = self.wrapper.read_bytes()
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--check"]), 0)
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 0)
            self.assertEqual(self.wrapper.read_bytes(), updated)

    def test_mixed_optional_and_declared_crane_wrappers_sync_only_declared(self):
        declared = self.root / "pkgs/declared/flake.nix"
        declared.parent.mkdir()
        declared.write_text(WRAPPER_WITH_CRANE)
        lock = root_lock()
        lock["nodes"]["crane_selected"]["original"]["ref"] = "v1.2.3"
        (self.root / "flake.lock").write_text(json.dumps(lock))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 0)
            self.assertNotIn("crane", self.wrapper.read_text())
            self.assertIn('crane.url = "github:ipetkov/crane/v1.2.3";', declared.read_text())
            before = {path: path.read_bytes() for path in (self.wrapper, declared)}
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--check"]), 0)
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 0)
        for path, original in before.items():
            self.assertEqual(path.read_bytes(), original)

    def test_validation_completes_before_any_write(self):
        broken = self.root / "pkgs/z-broken/flake.nix"
        broken.parent.mkdir()
        broken.write_text(WRAPPER.replace('nixpkgs.url = "old";', ""))
        before = self.wrapper.read_text()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(pins.main(["child-refs", "--root", str(self.root), "--write"]), 2)
        self.assertEqual(self.wrapper.read_text(), before)

    def test_malformed_inputs_never_partially_write(self):
        broken = self.root / "pkgs/z-broken/flake.nix"
        broken.parent.mkdir()
        malformed = (
            WRAPPER.replace('nixpkgs.url = "old";', 'nixpkgs.url = "old"'),
            WRAPPER.replace('nixpkgs.url = "old";', 'nixpkgs.url = ("old"];'),
            WRAPPER.replace("  };", ""),
            WRAPPER.replace("  inputs = {", "  inputs = {}; inputs = {"),
            WRAPPER.replace('nixpkgs.url = "old";',
                            'nixpkgs.url = "old"; nixpkgs.url = "duplicate";'),
        )
        for text in malformed:
            for mode in ("--check", "--write"):
                with self.subTest(text=text, mode=mode):
                    broken.write_text(text)
                    before = {path: path.read_bytes() for path in (self.wrapper, broken)}
                    stdout, stderr = io.StringIO(), io.StringIO()
                    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                        self.assertEqual(pins.main(["child-refs", "--root", str(self.root), mode]), 2)
                    self.assertTrue(stderr.getvalue())
                    self.assertEqual(stdout.getvalue(), "")
                    for path, original in before.items():
                        self.assertEqual(path.read_bytes(), original)

    def test_unsupported_input_cli_failure_never_writes_any_wrapper(self):
        broken = self.root / "pkgs/z-broken/flake.nix"
        broken.parent.mkdir()
        for declaration in UNSUPPORTED_CRANE_DECLARATIONS:
            for mode in ("--check", "--write"):
                with self.subTest(declaration=declaration, mode=mode):
                    broken.write_text(WRAPPER.replace(
                        "  inputs = {", f"  inputs = {{\n    {declaration}"
                    ))
                    before = {path: path.read_text() for path in (self.wrapper, broken)}
                    stdout, stderr = io.StringIO(), io.StringIO()
                    with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                        status = pins.main(["child-refs", "--root", str(self.root), mode])
                    self.assertEqual(status, 2)
                    self.assertIn("unsupported", stderr.getvalue())
                    self.assertNotIn("match root", stdout.getvalue())
                    for path, original in before.items():
                        self.assertEqual(path.read_text(), original)


class UpdateScriptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(
            prefix="child refs ", dir=TEST_TMP
        )
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        self.updater = self.root / "scripts/update.sh"
        self.updater.write_text((REPO_ROOT / "scripts/update.sh").read_text())
        self.child = self.root / "pkgs/pilot"
        self.child.mkdir(parents=True)
        self.locks = [self.root / "flake.lock", self.child / "flake.lock"]
        for lock in self.locks:
            lock.write_text("unchanged fixture\n")
        self.events = self.root / "events"

    def run_updater(self, *args, nix_status=0, sync_status=0):
        # Source the actual entrypoint in a disposable repo. Shell functions
        # intercept EVERY Nix/Python call, so no real updates/network can run.
        mocks = r'''
set -Eeuo pipefail
nix() {
    printf 'nix' >> "$EVENTS"
    printf '\t%s' "$@" >> "$EVENTS"
    printf '\n' >> "$EVENTS"
    return "$NIX_STATUS"
}
python3() {
    if [[ "$1" == "-c" ]]; then
        while IFS= read -r line; do :; done
        printf 'python3-report\n' >> "$EVENTS"
        return 0
    fi
    if [[ "${2:-}" == "flake-dirs" ]]; then
        printf 'python3' >> "$EVENTS"
        printf '\t%s' "$@" >> "$EVENTS"
        printf '\n' >> "$EVENTS"
        # Emulate update-helper discovery: root first, then the child lock.
        printf '%s\0%s\0' "$REPO_ROOT" "$REPO_ROOT/pkgs/pilot"
        return 0
    fi
    printf 'python3' >> "$EVENTS"
    printf '\t%s' "$@" >> "$EVENTS"
    printf '\n' >> "$EVENTS"
    return "$SYNC_STATUS"
}
source "$1" "${@:2}"
'''
        env = {
            **os.environ, "GITHUB_TOKEN": "", "GH_TOKEN": "",
            "EVENTS": str(self.events), "NIX_STATUS": str(nix_status),
            "SYNC_STATUS": str(sync_status),
        }
        result = subprocess.run(
            ["bash", "-c", mocks, "mocked-update", str(self.updater), *args],
            env=env, capture_output=True, text=True, timeout=10,
        )
        calls = [line.split("\t") for line in self.events.read_text().splitlines()]
        for lock in self.locks:
            self.assertEqual(lock.read_text(), "unchanged fixture\n")
        return result, calls

    def test_root_update_ref_sync_child_lock_order(self):
        result, calls = self.run_updater("--only-flake")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            ["nix", "flake", "update", "--flake", str(self.root)],
            ["python3", str(self.root / "scripts/support/update-helper.py"),
             "child-refs", "--root", str(self.root), "--write"],
            ["python3", str(self.root / "scripts/support/update-helper.py"),
             "flake-dirs", "--null", "--root", str(self.root)],
            ["nix", "flake", "update", "--flake", str(self.child)],
        ])

    def test_failed_root_update_stops_before_ref_sync(self):
        result, calls = self.run_updater("--only-flake", nix_status=7)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(calls, [["nix", "flake", "update", "--flake", str(self.root)]])

    def test_failed_ref_sync_stops_before_child_locks(self):
        result, calls = self.run_updater("--only-flake", sync_status=2)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[1][0], "python3")
        self.assertEqual(calls[1][-1], "--write")

    def test_report_never_updates_locks_or_syncs_refs(self):
        result, calls = self.run_updater("--only-flake", "--report", "--color=never")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sorted(calls), sorted([
            ["nix", "--no-warn-dirty", "flake", "metadata", "--no-write-lock-file",
             "--json", str(self.root)],
            ["python3-report"],
        ]))


if __name__ == "__main__":
    unittest.main()
