import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).parents[3]
UPDATE_SCRIPT = REPO_ROOT / "lib/ext/prism-llama-cpp/update.sh"
TMP_ROOT = REPO_ROOT / "tmp"


class PrismLlamaCppUpdateTests(unittest.TestCase):
    def setUp(self):
        TMP_ROOT.mkdir(exist_ok=True)
        self.temp_dir = tempfile.TemporaryDirectory(
            prefix="test-prism-update.", dir=TMP_ROOT
        )
        self.root = Path(self.temp_dir.name)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.trace = self.root / "curl-args"
        self.source = self.root / "sources.nix"
        self.source.write_text('version = "prism-old";\n')

    def tearDown(self):
        self.temp_dir.cleanup()

    def install_curl(self, response):
        curl = self.bin_dir / "curl"
        curl.write_text(
            f"#!{shutil.which('bash')}\n"
            'printf "%s\\n" "$@" >"$TRACE"\n'
            f"printf '%s\\n' '{response}'\n"
        )
        curl.chmod(0o755)

    def run_update(self, token="gh_test_token"):
        env = os.environ.copy()
        env.update(
            {
                "GITHUB_TOKEN": token,
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "TRACE": str(self.trace),
                "UPDATE_PRISM_LLAMA_CPP_IN_NIX_SHELL": "1",
            }
        )
        return subprocess.run(
            ["bash", UPDATE_SCRIPT, "--report", "--file", self.source],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )

    def test_release_lookup_uses_normalized_github_token(self):
        self.install_curl('[{"tag_name":"prism-new"}]')

        result = self.run_update()

        self.assertEqual(result.returncode, 0, result.stderr)
        curl_args = self.trace.read_text().splitlines()
        self.assertIn("Authorization: Bearer gh_test_token", curl_args)
        self.assertIn("Accept: application/vnd.github+json", curl_args)
        self.assertIn("abird-prism-llama-cpp-updater", curl_args)
        self.assertNotIn("gh_test_token", result.stdout)
        self.assertNotIn("gh_test_token", result.stderr)

    def test_missing_prism_release_has_controlled_error(self):
        self.install_curl("[]")

        result = self.run_update(token="")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "Could not resolve latest PrismML llama.cpp release tag", result.stderr
        )


if __name__ == "__main__":
    unittest.main()
