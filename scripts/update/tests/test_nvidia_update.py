import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[3]
CURRENT = "620.70.06"
CANDIDATE = "595.112.13"
ARTIFACTS = [
    f"NVIDIA-Linux-x86_64-{CANDIDATE}.run",
    "open-gpu-kernel-modules",
    "nvidia-settings",
    "nvidia-persistenced",
]


class NvidiaUpdateTests(unittest.TestCase):
    def setUp(self):
        scratch = REPO_ROOT / "tmp"
        scratch.mkdir(exist_ok=True)
        temp = tempfile.TemporaryDirectory(prefix="test-nvidia-update.", dir=scratch)
        self.addCleanup(temp.cleanup)
        self.repo = Path(temp.name)
        self.unit = self.repo / "lib/ext/nvidia"
        self.unit.mkdir(parents=True)
        (self.repo / "scripts").mkdir()
        shutil.copy2(REPO_ROOT / "lib/ext/nvidia/update.sh", self.unit)
        shutil.copy2(REPO_ROOT / "scripts/update.sh", self.repo / "scripts")
        self.source = self.unit / "sources.nix"
        self.initial = f'''{{
  nvidia = {{
    branch = "production";
    version = "{CURRENT}";
    sha256_64bit = "old";
    openSha256 = "old";
    settingsSha256 = "old";
    persistencedSha256 = "old";
  }};
}}
'''
        self.source.write_text(self.initial)
        self.trace = self.repo / "trace"
        self.bin = self.repo / "bin"
        self.bin.mkdir()
        self.stub("curl", '''
url="${@: -1}"
case "$url" in
*AjaxDriverService.php*)
    printf '{"IDS":[{"downloadInfo":{"DisplayVersion":"%s","IsRecommended":"1"}}]}\\n' "$CANDIDATE"
    ;;
*/releases/tag/*) exit 22 ;;
*)
    [[ "$1" == -*I* && "$1" == -*L* ]] || exit 2
    printf 'head %s\\n' "$url" >>"$TRACE"
    case "$url" in
        *"${UNAVAILABLE:-never-match}"*) printf '%s' "${STATUS:-404}" ;;
        *) printf '200' ;;
    esac
    ;;
esac
''')
        self.stub("nix", '''
[[ "$1 $2" == "store prefetch-file" ]] || exit 2
printf 'prefetch %s\\n' "${@: -1}" >>"$TRACE"
printf '{"hash":"sha256-test"}\\n'
''')
        self.stub("alejandra", "exit 0\n")

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{shutil.which('bash')}\nset -euo pipefail\n{body}")
        path.chmod(0o755)

    def run_updater(self, *args, suite=False, unavailable="never-match", status="404"):
        env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "UPDATE_NVIDIA_IN_NIX_SHELL": "1",
            "TRACE": str(self.trace),
            "CANDIDATE": CANDIDATE,
            "UNAVAILABLE": unavailable,
            "STATUS": status,
        }
        env.pop("GITHUB_TOKEN", None)
        env.pop("GH_TOKEN", None)
        script = "scripts/update.sh" if suite else "lib/ext/nvidia/update.sh"
        return subprocess.run(
            ["bash", self.repo / script, *args],
            check=False,
            capture_output=True,
            text=True,
            env=env,
            timeout=15,
        )

    def assert_artifacts_checked(self, lines, operation):
        self.assertEqual(len(lines), len(ARTIFACTS))
        for line, artifact in zip(lines, ARTIFACTS, strict=True):
            self.assertTrue(line.startswith(f"{operation} "), line)
            self.assertIn(artifact, line)
            self.assertIn(CANDIDATE, line)

    def test_missing_artifact_skips_update_and_later_updaters_continue(self):
        later = self.repo / "lib/ext/zzz-later"
        later.mkdir()
        (later / "sources.nix").write_text("{}\n")
        script = later / "update.sh"
        script.write_text(f"#!{shutil.which('bash')}\nprintf 'later updater ran\\n'\n")
        script.chmod(0o755)

        result = self.run_updater("--only-ext", suite=True, unavailable="NVIDIA/nvidia-")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("later updater ran", result.stdout)
        self.assertIn(f"NVIDIA {CANDIDATE} is missing", result.stderr)
        self.assertIn(f"keeping {CURRENT}", result.stderr)
        for artifact in ARTIFACTS[2:]:
            self.assertIn(f"HTTP 404: https://github.com/NVIDIA/{artifact}/", result.stderr)
        self.assert_artifacts_checked(self.trace.read_text().splitlines(), "head")
        self.assertEqual(self.source.read_text(), self.initial)

    def test_missing_runfile_is_reported_without_offering_update(self):
        result = self.run_updater("--report", unavailable="download.nvidia.com")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"keeping {CURRENT}", result.stderr)
        self.assertIn("HTTP 404: https://download.nvidia.com/", result.stderr)
        self.assertNotIn("->", result.stdout)
        self.assert_artifacts_checked(self.trace.read_text().splitlines(), "head")
        self.assertEqual(self.source.read_text(), self.initial)

    def test_all_artifacts_checked_before_any_prefetch(self):
        result = self.run_updater("--version", CANDIDATE)

        self.assertEqual(result.returncode, 0, result.stderr)
        lines = self.trace.read_text().splitlines()
        self.assert_artifacts_checked(lines[: len(ARTIFACTS)], "head")
        self.assert_artifacts_checked(lines[len(ARTIFACTS) :], "prefetch")
        updated = self.source.read_text()
        self.assertIn(f'version = "{CANDIDATE}";', updated)
        self.assertEqual(updated.count('"sha256-test"'), 4)

    def test_service_error_is_not_a_missing_artifact(self):
        result = self.run_updater(
            "--version", CANDIDATE, unavailable="nvidia-settings", status="503"
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not check", result.stderr)
        self.assertIn("HTTP 503", result.stderr)
        self.assertNotIn("missing required artifacts", result.stderr)
        self.assertNotIn("prefetch", self.trace.read_text())
        self.assertEqual(self.source.read_text(), self.initial)

    def test_current_pin_skips_artifact_checks(self):
        result = self.run_updater("--version", CURRENT)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skipping prefetch", result.stdout)
        self.assertFalse(self.trace.exists())
        self.assertEqual(self.source.read_text(), self.initial)


if __name__ == "__main__":
    unittest.main()
