import contextlib
import importlib.util
import io
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "scripts/support/update-helper.py"
TMP_ROOT = REPO_ROOT / "tmp/helper-consolidation"
SPEC = importlib.util.spec_from_file_location("update_helper_flake_dirs", SCRIPT)
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


class FlakeDirDiscoveryTests(unittest.TestCase):
    def setUp(self):
        TMP_ROOT.mkdir(parents=True, exist_ok=True)
        self.temp_dir = tempfile.TemporaryDirectory(
            prefix="test-flake-dirs.", dir=TMP_ROOT
        )
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)

    def add_flake(self, *parts):
        directory = self.root.joinpath(*parts)
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "flake.nix").write_text("outputs = inputs: {};\n")
        (directory / "flake.lock").write_text("{}\n")
        return directory

    def init_git(self, ignore):
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / ".gitignore").write_text(ignore)

    def test_discovers_root_first_then_sorted_locks(self):
        self.add_flake("pkgs/zulu")
        self.add_flake("pkgs/alpha/nested")
        self.add_flake("lib/tool")
        self.add_flake()  # root
        (self.root / "pkgs/empty").mkdir(parents=True)

        self.assertEqual(
            [Path("."), Path("lib/tool"), Path("pkgs/alpha/nested"), Path("pkgs/zulu")],
            [path.relative_to(self.root) for path in HELPER.discover_flake_dirs(self.root)],
        )

    def test_git_ignored_directories_are_pruned(self):
        # Mirrors the repository layout: Git ignores tmp/ and worktrees/, and it
        # ignores nested flake.lock files, but a child lock's parent directory
        # stays discoverable because only directories are pruned.
        self.add_flake("tmp/design-g4/probe/vendor/sharded-slab")
        self.add_flake("worktrees/session")
        child = self.add_flake("pkgs/tools/abird-host-agent")
        self.add_flake()  # root
        self.init_git("tmp/\nworktrees/\nflake.lock\n!/flake.lock\n")

        self.assertEqual(
            [self.root, child],
            HELPER.discover_flake_dirs(self.root),
        )

    def test_generated_names_are_pruned_without_git_metadata(self):
        for name in ("node_modules", "target", "dist", ".direnv", "tmp", "worktrees"):
            self.add_flake(name, "scratch")
        self.add_flake(".git", "hooks")
        kept = self.add_flake("pkgs/kept")
        self.add_flake()  # root

        found = [path.relative_to(self.root) for path in HELPER.discover_flake_dirs(self.root)]
        self.assertEqual([Path("."), Path("pkgs/kept")], found)
        self.assertIn(kept, HELPER.discover_flake_dirs(self.root))

    def test_missing_root_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "missing repository root"):
            HELPER.discover_flake_dirs(self.root / "does-not-exist")

    def test_flake_dirs_cli_separates_paths_by_newline_or_nul(self):
        self.add_flake("pkgs/alpha")
        self.add_flake()  # root
        for argv, separator in (([], "\n"), (["--null"], "\0")):
            with self.subTest(argv=argv):
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    status = HELPER.main(["flake-dirs", "--root", str(self.root), *argv])
                self.assertEqual(status, 0)
                self.assertEqual(
                    [str(self.root), str(self.root / "pkgs/alpha")],
                    stdout.getvalue().split(separator)[:2],
                )
                self.assertTrue(stdout.getvalue().endswith(separator))

    def test_flake_dirs_dispatch_never_reports_or_syncs_refs(self):
        with mock.patch.object(
            HELPER, "discover_flake_dirs", return_value=[self.root]
        ) as discovery, \
                mock.patch.object(HELPER, "report_sources") as report, \
                mock.patch.object(HELPER, "sync_child_refs") as refs, \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(HELPER.main(["flake-dirs", "--root", str(self.root)]), 0)
        discovery.assert_called_once_with(self.root)
        report.assert_not_called()
        refs.assert_not_called()

    def test_discovery_failure_reports_status_two(self):
        stderr = io.StringIO()
        with mock.patch.object(
            HELPER, "discover_flake_dirs", side_effect=ValueError("no root")
        ), contextlib.redirect_stderr(stderr):
            self.assertEqual(HELPER.main(["flake-dirs", "--root", str(self.root)]), 2)
        self.assertIn("update-helper flake-dirs: no root", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
