import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class OllamaHelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[4]
        cls.helper = cls.repo_root / "lib/services/ollama/helper.sh"
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def setUp(self):
        self.work_dir = Path(tempfile.mkdtemp(prefix="ollama-helper-test.", dir=self.tmp_root))
        self.fake_bin = self.work_dir / "bin"
        self.state_dir = self.work_dir / "state"
        self.fake_bin.mkdir()
        self.state_dir.mkdir()
        self.write_fake_curl()
        self.write_fake_sleep()
        self.write_fake_systemctl()
        self.write_fake_awk()

    def tearDown(self):
        shutil.rmtree(self.work_dir)

    def write_executable(self, path: Path, body: str):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def write_fake_curl(self):
        log_path = self.state_dir / "curl.log"
        self.write_executable(
            self.fake_bin / "curl",
            f"""#!/bin/sh
printf '%s\\n' "$*" >> {log_path}
url=""
for arg in "$@"; do
  url="$arg"
done
case "$url" in
  */api/tags)
    if [ "${{FAKE_CURL_TAGS_STATUS:-7}}" != 0 ]; then
      exit "$FAKE_CURL_TAGS_STATUS"
    fi
    if [ -n "${{FAKE_CURL_TAGS_RESPONSE+x}}" ]; then
      printf '%s\\n' "$FAKE_CURL_TAGS_RESPONSE"
    else
      printf '%s\\n' '{{"models":[]}}'
    fi
    ;;
  */api/pull)
    if [ "${{FAKE_CURL_PULL_STATUS:-0}}" != 0 ]; then
      exit "$FAKE_CURL_PULL_STATUS"
    fi
    if [ -n "${{FAKE_CURL_PULL_RESPONSE+x}}" ]; then
      printf '%s\\n' "$FAKE_CURL_PULL_RESPONSE"
    else
      printf '%s\\n' '{{"status":"success"}}'
    fi
    ;;
  *)
    exit 7
    ;;
esac
""",
        )

    def write_fake_sleep(self):
        log_path = self.state_dir / "sleep.log"
        self.write_executable(
            self.fake_bin / "sleep",
            f"""#!/bin/sh
printf '%s\\n' "$*" >> {log_path}
exit "${{FAKE_SLEEP_STATUS:-0}}"
""",
        )

    def write_fake_awk(self):
        self.write_executable(
            self.fake_bin / "awk",
            """#!/bin/sh
printf '%s\n' "awk should not be required" >&2
exit 127
""",
        )

    def write_fake_systemctl(self):
        log_path = self.state_dir / "systemctl.log"
        states_dir = self.state_dir / "unit-states"
        self.write_executable(
            self.fake_bin / "systemctl",
            f"""#!/bin/sh
set -eu
printf '%s\\n' "$*" >> {log_path}
if [ "${{1-}}" = "--user" ]; then
  shift
fi
cmd="${{1-}}"
if [ "$#" -gt 0 ]; then
  shift
fi
case "$cmd" in
  show)
    property=""
    unit=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --property=*) property="${{1#--property=}}" ;;
        --value) ;;
        *) unit="$1" ;;
      esac
      shift
    done
    case "$property" in
      ActiveState)
        if [ -n "$unit" ]; then
          state_file="{states_dir}/$unit"
          if [ -f "$state_file" ]; then
            cat "$state_file"
          else
            printf '%s\\n' "active"
          fi
        fi
        ;;
      After)
        case "$unit" in
          pvl-ollama-models.service)
            printf '%s\\n' "pvl-ollama.service pvl-ollama-nvidia.service network-online.target"
            ;;
        esac
        ;;
    esac
    ;;
  try-restart)
    if [ "${{FAKE_SYSTEMCTL_TRY_RESTART_STATUS:-0}}" != 0 ]; then
      exit "$FAKE_SYSTEMCTL_TRY_RESTART_STATUS"
    fi
    ;;
esac
""",
        )

    def set_unit_state(self, unit: str, state: str):
        states_dir = self.state_dir / "unit-states"
        states_dir.mkdir(exist_ok=True)
        (states_dir / unit).write_text(f"{state}\n", encoding="utf-8")

    def read_log(self, name: str):
        path = self.state_dir / name
        if not path.exists():
            return []
        return path.read_text(encoding="utf-8").splitlines()

    def helper_env(self, **overrides):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.fake_bin}:{env['PATH']}",
                "OLLAMA_URLS": "http://127.0.0.1:11434 http://127.0.0.1:11435",
                "OLLAMA_CURRENT_UNIT": "pvl-ollama-models.service",
            }
        )
        env.update(overrides)
        return env

    def run_helper(self, *, check=True, **env_overrides):
        return subprocess.run(
            ["bash", str(self.helper), "nomic-embed-text"],
            cwd=self.repo_root,
            env=self.helper_env(**env_overrides),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def test_skip_if_configured_backends_are_inactive(self):
        self.set_unit_state("pvl-ollama.service", "inactive")
        self.set_unit_state("pvl-ollama-nvidia.service", "failed")

        result = self.run_helper(
            OLLAMA_WAIT_ATTEMPTS="120",
            OLLAMA_WAIT_DELAY_SECONDS="60",
            FAKE_SLEEP_STATUS="99",
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn("dependent service units are inactive", result.stderr)
        self.assertEqual(self.read_log("sleep.log"), [])
        self.assertEqual(len(self.read_log("curl.log")), 2)

    def test_active_backend_keeps_normal_wait_path(self):
        self.set_unit_state("pvl-ollama.service", "active")
        self.set_unit_state("pvl-ollama-nvidia.service", "inactive")

        result = self.run_helper(
            check=False,
            OLLAMA_WAIT_ATTEMPTS="2",
            OLLAMA_WAIT_DELAY_SECONDS="0",
        )

        self.assertEqual(result.returncode, 1)
        self.assertNotIn("dependent service units are inactive", result.stderr)
        self.assertIn("no Ollama API available", result.stderr)
        self.assertEqual(len(self.read_log("curl.log")), 4)
        self.assertEqual(self.read_log("sleep.log"), ["0"])

    def test_downloaded_model_try_restarts_dependent_services(self):
        self.set_unit_state("pvl-ollama.service", "active")
        self.set_unit_state("pvl-ollama-nvidia.service", "inactive")

        result = self.run_helper(
            FAKE_CURL_TAGS_STATUS="0",
            FAKE_CURL_TAGS_RESPONSE='{"models":[]}',
        )

        self.assertEqual(result.returncode, 0)
        systemctl_log = "\n".join(self.read_log("systemctl.log"))
        self.assertIn("--user try-restart pvl-ollama.service", systemctl_log)
        self.assertIn("--user try-restart pvl-ollama-nvidia.service", systemctl_log)

    def test_existing_model_does_not_restart_dependencies(self):
        self.set_unit_state("pvl-ollama.service", "active")
        self.set_unit_state("pvl-ollama-nvidia.service", "inactive")

        result = self.run_helper(
            FAKE_CURL_TAGS_STATUS="0",
            FAKE_CURL_TAGS_RESPONSE='{"models":[{"name":"nomic-embed-text:latest"}]}',
        )

        self.assertEqual(result.returncode, 0)
        systemctl_log = "\n".join(self.read_log("systemctl.log"))
        self.assertNotIn("try-restart", systemctl_log)
