import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).parents[3]
UPDATE_SCRIPT = REPO_ROOT / "scripts/update.sh"
TMP_ROOT = REPO_ROOT / "tmp"


class UpdateSourceDiscoveryTests(unittest.TestCase):
    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.temp_dir = tempfile.TemporaryDirectory(
            prefix="test-update-discovery.", dir=TMP_ROOT
        )
        self.repo = Path(self.temp_dir.name) / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "scripts/support").mkdir(parents=True)
        (self.repo / "lib/ext").mkdir(parents=True)
        (self.repo / "pkgs/ext").mkdir(parents=True)
        shutil.copy2(UPDATE_SCRIPT, self.repo / "scripts/update.sh")

    def tearDown(self):
        self.temp_dir.cleanup()

    def add_unit(self, root, name, sources=False, updater=False):
        unit = self.repo / root / name
        unit.mkdir(parents=True)
        if sources:
            (unit / "sources.nix").write_text("{}\n")
        if updater:
            script = unit / "update.sh"
            script.write_text('#!/usr/bin/env bash\nprintf invoked >"$TRACE"\n')
            script.chmod(0o755)
        return unit

    def run_update(self, *args, trace=None):
        env = os.environ.copy()
        if trace is not None:
            env["TRACE"] = str(trace)
        return subprocess.run(
            [self.repo / "scripts/update.sh", *args],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def test_sources_and_updater_participate_in_updates(self):
        trace = Path(self.temp_dir.name) / "trace"
        self.add_unit("lib/ext", "example", sources=True, updater=True)

        result = self.run_update("--only-ext", trace=trace)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace.read_text(), "invoked")

    def test_sources_without_updater_are_report_only(self):
        unit = self.add_unit("pkgs/ext", "example", sources=True)
        trace = Path(self.temp_dir.name) / "trace"
        reporter = self.repo / "scripts/support/report-ext-sources.py"
        reporter.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@" >"$TRACE"\n')
        reporter.chmod(0o755)

        result = self.run_update("--report", "--only-pkgs-ext", trace=trace)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(unit / "sources.nix"), trace.read_text().splitlines())

        trace.unlink()
        result = self.run_update("--only-pkgs-ext", trace=trace)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(trace.exists())
        self.assertIn("No external update scripts selected", result.stdout)

    def test_directory_without_convention_files_is_ignored(self):
        self.add_unit("lib/ext", "example")

        result = self.run_update("--only-ext")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No external update scripts selected", result.stdout)

    def test_updater_without_sources_is_rejected(self):
        self.add_unit("lib/ext", "example", updater=True)

        result = self.run_update("--only-ext")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("has no sibling sources.nix", result.stderr)

    def test_non_executable_updater_is_rejected(self):
        unit = self.add_unit("lib/ext", "example", sources=True, updater=True)
        (unit / "update.sh").chmod(0o644)

        result = self.run_update("--only-ext")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is not executable", result.stderr)

    def test_podman_images_report_and_update_use_same_tool(self):
        trace = Path(self.temp_dir.name) / "trace"
        updater = self.repo / "scripts/support/podman-image-updater.py"
        updater.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@" >"$TRACE"\n')
        updater.chmod(0o755)

        result = self.run_update("--report", "--only-images", trace=trace)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--report", trace.read_text().splitlines())

        trace.unlink()
        result = self.run_update("--only-images", trace=trace)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("--report", trace.read_text().splitlines())


if __name__ == "__main__":
    unittest.main()
