import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


class ForgejoHelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[4]
        cls.helper = cls.repo_root / "lib/services/forgejo/helper.sh"
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def setUp(self):
        self.work_dir = Path(tempfile.mkdtemp(prefix="forgejo-helper-test.", dir=self.tmp_root))
        self.fake_bin = self.work_dir / "bin"
        self.fake_bin.mkdir()

    def tearDown(self):
        shutil.rmtree(self.work_dir)

    def write_executable(self, path: Path, body: str):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def write_fake_curl(self, status: int, stderr: str = "", stdout: str = ""):
        self.write_executable(
            self.fake_bin / "curl",
            f"""#!/bin/sh
printf '%s' {stderr!r} >&2
printf '%s' {stdout!r}
exit {status}
""",
        )

    def run_wait_for_oidc_discovery(self):
        env = os.environ.copy()
        env["PATH"] = f"{self.fake_bin}:{env['PATH']}"
        script = f"""
source {self.helper}
forgejo_issuer_url=https://zauth.abird.ai/oauth2/openid/forgejo
forgejo_wait_seconds=0
wait_for_oidc_discovery
"""
        return subprocess.run(
            ["bash", "-c", script],
            cwd=self.repo_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def run_wait_for_oidc_discovery_with_resolve(self):
        args_file = self.work_dir / "curl.args"
        self.write_executable(
            self.fake_bin / "curl",
            f"""#!/bin/sh
printf '%s\\n' "$@" > {str(args_file)!r}
exit 0
""",
        )
        env = os.environ.copy()
        env["PATH"] = f"{self.fake_bin}:{env['PATH']}"
        script = f"""
source {self.helper}
forgejo_issuer_url=https://zauth.abird.ai/oauth2/openid/forgejo
forgejo_issuer_host_address=10.10.100.30
forgejo_wait_seconds=0
wait_for_oidc_discovery
"""
        result = subprocess.run(
            ["bash", "-c", script],
            cwd=self.repo_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        return result, args_file.read_text(encoding="utf-8")

    def run_forgejo_cli_retry(self, transient: bool):
        counter = self.work_dir / "count"
        message = (
            "Command error: dial tcp: lookup postgres on 10.89.25.1:53: no such host"
            if transient
            else "Command error: invalid auth source"
        )
        script = f"""
set -e
source {self.helper}
forgejo_wait_seconds=2
counter={counter}
forgejo_cli() {{
  count=0
  if [ -f "$counter" ]; then
    count="$(cat "$counter")"
  fi
  count=$((count + 1))
  printf '%s' "$count" >"$counter"
  if [ "$count" -eq 1 ]; then
    printf '%s\\n' {message!r} >&2
    return 1
  fi
  printf '%s\\n' 'ok'
}}
forgejo_cli_retry admin auth update-oauth
"""
        return subprocess.run(
            ["bash", "-c", script],
            cwd=self.repo_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def run_forgejo_cli_retry_slow_transient(self):
        counter = self.work_dir / "count"
        script = f"""
set -e
source {self.helper}
forgejo_wait_seconds=1
counter={counter}
forgejo_cli() {{
  count=0
  if [ -f "$counter" ]; then
    count="$(cat "$counter")"
  fi
  count=$((count + 1))
  printf '%s' "$count" >"$counter"
  sleep 3
  printf '%s\\n' 'Command error: dial tcp: lookup postgres on 10.89.25.1:53: read: connection refused' >&2
  return 1
}}
forgejo_cli_retry admin auth update-oauth
"""
        started = time.monotonic()
        result = subprocess.run(
            ["bash", "-c", script],
            cwd=self.repo_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        elapsed = time.monotonic() - started
        return result, elapsed, counter.read_text(encoding="utf-8")

    def test_oidc_discovery_404_is_non_fatal_skip(self):
        self.write_fake_curl(22, stderr="curl: (22) The requested URL returned error: 404\n")

        result = self.run_wait_for_oidc_discovery()

        self.assertEqual(result.returncode, 75, result.stderr)
        self.assertIn("skipping Forgejo auth-source apply for this switch", result.stderr)

    def test_oidc_discovery_non_404_fails_hard(self):
        self.write_fake_curl(7, stderr="curl: (7) Failed to connect\n")

        result = self.run_wait_for_oidc_discovery()

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn("skipping Forgejo auth-source apply for this switch", result.stderr)

    def test_oidc_discovery_uses_internal_resolve_address(self):
        result, args = self.run_wait_for_oidc_discovery_with_resolve()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--resolve", args)
        self.assertIn("zauth.abird.ai:443:10.10.100.30", args)
        self.assertIn("https://zauth.abird.ai/oauth2/openid/forgejo/.well-known/openid-configuration", args)

    def test_cli_retry_retries_transient_compose_dns_failure(self):
        result = self.run_forgejo_cli_retry(transient=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("ok", result.stdout)

    def test_cli_retry_keeps_non_transient_failure_hard(self):
        result = self.run_forgejo_cli_retry(transient=False)

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("invalid auth source", result.stderr)
        self.assertNotIn("ok", result.stdout)

    def test_cli_retry_counts_command_time_against_wait_budget(self):
        result, elapsed, count = self.run_forgejo_cli_retry_slow_transient()

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(count, "1")
        self.assertLess(elapsed, 5)

    def test_cli_call_has_a_hard_per_attempt_timeout(self):
        self.write_executable(
            self.fake_bin / "podman",
            "#!/bin/sh\ntrap 'exit 143' TERM\nsleep 30\n",
        )
        env = os.environ.copy()
        env["PATH"] = f"{self.fake_bin}:{env['PATH']}"
        script = f"""
source {self.helper}
forgejo_cli_timeout_seconds=1
forgejo_container=forgejo_forgejo_1
forgejo_work_path=/var/lib/gitea
forgejo_config_path=/var/lib/gitea/custom/conf/app.ini
forgejo_cli admin auth list
"""

        started = time.monotonic()
        result = subprocess.run(
            ["bash", "-c", script],
            cwd=self.repo_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=5,
        )
        elapsed = time.monotonic() - started

        self.assertEqual(124, result.returncode, result.stderr)
        self.assertIn("Forgejo CLI timed out after 1s", result.stderr)
        self.assertLess(elapsed, 4)


if __name__ == "__main__":
    unittest.main()
