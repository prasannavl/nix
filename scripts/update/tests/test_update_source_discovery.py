import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).parents[3]
UPDATE_SCRIPT = REPO_ROOT / "scripts/update.sh"
TMP_ROOT = REPO_ROOT / "tmp/helper-consolidation"


class UpdateSourceDiscoveryTests(unittest.TestCase):
    def setUp(self):
        TMP_ROOT.mkdir(parents=True, exist_ok=True)
        self.temp_dir = tempfile.TemporaryDirectory(
            prefix="test-update-discovery.", dir=TMP_ROOT
        )
        self.repo = Path(self.temp_dir.name) / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "scripts/update").mkdir(parents=True)
        (self.repo / "lib/ext").mkdir(parents=True)
        (self.repo / "pkgs/ext").mkdir(parents=True)
        shutil.copy2(UPDATE_SCRIPT, self.repo / "scripts/update.sh")
        self.bin = self.repo / "bin"
        self.bin.mkdir()
        # Only fixture commands; never consult the host's gh login.
        for name in ("basename", "bash", "dirname", "find", "python3", "sort"):
            executable = shutil.which(name)
            self.assertIsNotNone(executable, f"missing test dependency: {name}")
            (self.bin / name).symlink_to(executable)

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

    def add_command(self, name, body):
        command = self.bin / name
        command.write_text(f"#!/usr/bin/env bash\n{body}\n")
        command.chmod(0o755)

    def run_update(self, *args, trace=None, env=None, xtrace=False):
        full_env = os.environ.copy()
        for name in ("GITHUB_TOKEN", "GH_TOKEN", "NIX_CONFIG"):
            full_env.pop(name, None)
        full_env["PATH"] = str(self.bin)
        full_env.update(env or {})
        if trace is not None:
            full_env["TRACE"] = str(trace)
        command = [self.bin / "bash", "-x"] if xtrace else []
        return subprocess.run(
            [*command, self.repo / "scripts/update.sh", *args],
            check=False,
            capture_output=True,
            text=True,
            env=full_env,
        )

    def trace_github_token(self):
        trace = Path(self.temp_dir.name) / "trace"
        unit = self.add_unit("lib/ext", "example", sources=True, updater=True)
        (unit / "update.sh").write_text(
            '#!/usr/bin/env bash\nprintf "%s\\n%s\\n" '
            '"${GITHUB_TOKEN-}" "${NIX_CONFIG-}" >"$TRACE"\n'
        )
        return trace

    def assert_github_token(self, trace, token):
        self.assertEqual(
            trace.read_text().splitlines(),
            [token, "warn-dirty = false", f"extra-access-tokens = github.com={token}"],
        )

    def test_explicit_github_token_configures_reporters_and_nix_without_gh(self):
        trace = self.trace_github_token()
        self.add_command("gh", 'printf called >"$TRACE.gh"\nexit 1')
        for github_token, expected in [("github_test_token", "github_test_token"), ("", "gh_test_token")]:
            with self.subTest(github_token=github_token):
                result = self.run_update(
                    "--only-ext",
                    trace=trace,
                    env={
                        "GH_TOKEN": "gh_test_token",
                        "GITHUB_TOKEN": github_token,
                        "NIX_CONFIG": "warn-dirty = false",
                    },
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_github_token(trace, expected)
                self.assertEqual(result.stderr, "GitHub auth: using token from environment\n")
                self.assertFalse(trace.with_suffix(".gh").exists())

    def test_gh_login_configures_reporters_and_nix_without_tracing_token(self):
        trace = self.trace_github_token()
        self.add_command(
            "gh",
            '[[ "$GH_PROMPT_DISABLED" == 1 && "$*" == "auth token --hostname github.com" ]] || exit 1\n'
            'printf "%s\\n" cached_test_token',
        )
        result = self.run_update(
            "--only-ext",
            trace=trace,
            env={"GH_HOST": "enterprise.example", "NIX_CONFIG": "warn-dirty = false"},
            xtrace=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_github_token(trace, "cached_test_token")
        self.assertIn("GitHub auth: using token from gh\n", result.stderr)
        self.assertNotIn("cached_test_token", result.stdout + result.stderr)
        self.assertIn("+ run_updates", result.stderr)

    def test_unavailable_gh_credentials_leave_nix_config_unchanged(self):
        trace = self.trace_github_token()
        for installed in (False, True):
            with self.subTest(installed=installed):
                if installed:
                    self.add_command("gh", "echo not-logged-in >&2\necho stray-output\nexit 1")
                result = self.run_update(
                    "--only-ext", trace=trace, env={"NIX_CONFIG": "warn-dirty = false"}
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "GitHub auth: public\n")
                self.assertEqual(trace.read_text().splitlines(), ["", "warn-dirty = false"])

    def test_sources_and_updater_participate_in_updates(self):
        trace = Path(self.temp_dir.name) / "trace"
        self.add_unit("lib/ext", "example", sources=True, updater=True)

        result = self.run_update("--only-ext", trace=trace)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(trace.read_text(), "invoked")

    def test_sources_without_updater_are_report_only(self):
        unit = self.add_unit("pkgs/ext", "example", sources=True)
        trace = Path(self.temp_dir.name) / "trace"
        reporter = self.repo / "scripts/update/helper.py"
        reporter.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$@" >"$TRACE"\n')
        reporter.chmod(0o755)

        result = self.run_update("--report", "--only-pkgs-ext", trace=trace)

        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = trace.read_text().splitlines()
        self.assertEqual(arguments[0], "report-sources")
        self.assertIn(str(unit / "sources.nix"), arguments)

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
        updater = self.repo / "scripts/update/podman-images.py"
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
        reporter = self.repo / "scripts/update/helper.py"
        reporter.write_text("#!/usr/bin/env bash\nexit 5\n")
        reporter.chmod(0o755)
        result = self.run_update("--only-pkgs-ext", "--report")
        self.assertEqual(result.returncode, 5, result.stderr)
        self.assertIn("pkgs/ext source report", result.stderr)
        self.assertIn("scripts/update/helper.py", result.stderr)
        self.assertIn("exit 5", result.stderr)

    def test_report_footer_names_failed_image_reporter(self):
        reporter = self.repo / "scripts/update/podman-images.py"
        reporter.write_text("#!/usr/bin/env bash\nexit 6\n")
        reporter.chmod(0o755)
        result = self.run_update("--only-images", "--report")
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertIn("Report failures:", result.stderr)
        self.assertIn("scripts/update/podman-images.py (exit 6)", result.stderr)

    def test_earlier_failure_is_reported_after_successful_image_report(self):
        unit = self.add_unit("lib/ext", "nvidia", sources=True, updater=True)
        (unit / "update.sh").write_text("#!/usr/bin/env bash\nexit 1\n")
        reporter = self.repo / "scripts/update/podman-images.py"
        reporter.write_text("#!/usr/bin/env bash\nprintf 'image report completed\\n'\n")
        reporter.chmod(0o755)
        result = self.run_update("--report", "--skip-flake", "--skip-pkgs-ext")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("image report completed", result.stdout)
        self.assertIn("lib/ext/nvidia/update.sh (exit 1)", result.stderr)
        self.assertNotIn("podman-images.py", result.stderr)

    def test_report_footer_names_failed_flake_metadata(self):
        self.add_command("nix", "printf '{}\\n'\nexit 3")
        result = self.run_update("--only-flake", "--report")
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("flake metadata (exit 3)", result.stderr)


if __name__ == "__main__":
    unittest.main()
