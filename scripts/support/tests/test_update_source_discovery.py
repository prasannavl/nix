import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


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

    def run_update(self, *args, trace=None, env=None):
        full_env = os.environ.copy()
        full_env.pop("GITHUB_TOKEN", None)
        full_env.pop("GH_TOKEN", None)
        full_env.update(env or {})
        if trace is not None:
            full_env["TRACE"] = str(trace)
        return subprocess.run(
            [self.repo / "scripts/update.sh", *args],
            check=False,
            capture_output=True,
            text=True,
            env=full_env,
        )

    def test_github_token_configures_reporters_and_nix(self):
        trace = Path(self.temp_dir.name) / "trace"
        unit = self.add_unit("lib/ext", "example", sources=True, updater=True)
        (unit / "update.sh").write_text(
            '#!/usr/bin/env bash\nprintf "%s\\n%s\\n" '
            '"$GITHUB_TOKEN" "$NIX_CONFIG" >"$TRACE"\n'
        )
        (unit / "update.sh").chmod(0o755)

        result = self.run_update(
            "--only-ext",
            trace=trace,
            env={
                "GH_TOKEN": "gh_test_token",
                "GITHUB_TOKEN": "",
                "NIX_CONFIG": "warn-dirty = false",
            },
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            trace.read_text().splitlines(),
            [
                "gh_test_token",
                "warn-dirty = false",
                "extra-access-tokens = github.com=gh_test_token",
            ],
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

    def test_report_footer_names_failed_updaters_with_serial_and_parallel_jobs(self):
        for name, status in [("bad-a", 7), ("bad-b", 9), ("good", 0)]:
            unit = self.add_unit("lib/ext", name, sources=True, updater=True)
            (unit / "update.sh").write_text(f"#!/usr/bin/env bash\nexit {status}\n")
        for jobs in [1, 4]:
            with self.subTest(jobs=jobs):
                result = self.run_update("--only-ext", "--report", "--jobs", str(jobs))
                self.assertEqual(result.returncode, 9, result.stderr)
                self.assertIn("Report failures:", result.stderr)
                self.assertIn("lib/ext/bad-a/update.sh (exit 7)", result.stderr)
                self.assertIn("lib/ext/bad-b/update.sh (exit 9)", result.stderr)
                self.assertNotIn("lib/ext/good/update.sh", result.stderr)

    def test_report_footer_names_failed_source_reporter(self):
        self.add_unit("pkgs/ext", "example", sources=True)
        reporter = self.repo / "scripts/support/report-ext-sources.py"
        reporter.write_text("#!/usr/bin/env bash\nexit 5\n")
        reporter.chmod(0o755)
        result = self.run_update("--only-pkgs-ext", "--report")
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertIn("pkgs/ext source report", result.stderr)
        self.assertIn("scripts/support/report-ext-sources.py", result.stderr)
        self.assertIn("exit 5", result.stderr)

    def test_report_footer_names_failed_image_reporter(self):
        reporter = self.repo / "scripts/support/podman-image-updater.py"
        reporter.write_text("#!/usr/bin/env bash\nexit 6\n")
        reporter.chmod(0o755)
        result = self.run_update("--only-images", "--report")
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertIn("Report failures:", result.stderr)
        self.assertIn("scripts/support/podman-image-updater.py (exit 6)", result.stderr)

    def test_earlier_failure_is_reported_after_successful_image_report(self):
        unit = self.add_unit("lib/ext", "nvidia", sources=True, updater=True)
        (unit / "update.sh").write_text("#!/usr/bin/env bash\nexit 1\n")
        reporter = self.repo / "scripts/support/podman-image-updater.py"
        reporter.write_text("#!/usr/bin/env bash\nprintf 'image report completed\\n'\n")
        reporter.chmod(0o755)
        result = self.run_update("--report", "--skip-flake", "--skip-pkgs-ext")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("image report completed", result.stdout)
        self.assertIn("lib/ext/nvidia/update.sh (exit 1)", result.stderr)
        self.assertNotIn("podman-image-updater.py", result.stderr)

    def test_report_footer_names_failed_flake_metadata(self):
        binary_dir = self.repo / "bin"
        binary_dir.mkdir()
        nix = binary_dir / "nix"
        nix.write_text("#!/usr/bin/env bash\nprintf '{}\\n'\nexit 3\n")
        nix.chmod(0o755)
        with mock.patch.dict(os.environ, {"PATH": f"{binary_dir}:{os.environ['PATH']}"}):
            result = self.run_update("--only-flake", "--report")
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("flake metadata (exit 3)", result.stderr)


if __name__ == "__main__":
    unittest.main()
