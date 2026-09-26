import json
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
        self.work_dir = Path(
            tempfile.mkdtemp(prefix="ollama-helper-test.", dir=self.tmp_root)
        )
        self.fake_bin = self.work_dir / "bin"
        self.state_dir = self.work_dir / "state"
        self.manifest = self.state_dir / "managed.json"
        self.fake_bin.mkdir()
        self.state_dir.mkdir()
        self.write_fake_curl()
        self.write_fake_sleep()
        self.write_fake_systemctl()

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
  */api/delete)
    if [ "${{FAKE_CURL_DELETE_STATUS:-0}}" != 0 ]; then
      exit "$FAKE_CURL_DELETE_STATUS"
    fi
    printf '%s\\n' '{{"status":"success"}}'
    ;;
  *) exit 7 ;;
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

    def write_fake_systemctl(self):
        log_path = self.state_dir / "systemctl.log"
        states_dir = self.state_dir / "unit-states"
        self.write_executable(
            self.fake_bin / "systemctl",
            f"""#!/bin/sh
set -eu
printf '%s\\n' "$*" >> {log_path}
if [ "${{1-}}" = "--user" ]; then shift; fi
cmd="${{1-}}"
if [ "$#" -gt 0 ]; then shift; fi
case "$cmd" in
  show)
    properties=""
    value_only=false
    unit=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --property=*) properties="$properties ${{1#--property=}}" ;;
        --value) value_only=true ;;
        *) unit="$1" ;;
      esac
      shift
    done
    transition_poll=0
    case " $properties " in
      *" Job "*)
        if [ "${{FAKE_SYSTEMCTL_RESTART_TRANSITION:-0}}" = 1 ]; then
          poll_file="{states_dir}/restart-transition-poll"
          if [ -f "$poll_file" ]; then transition_poll="$(cat "$poll_file")"; fi
          transition_poll=$((transition_poll + 1))
          printf '%s\\n' "$transition_poll" >"$poll_file"
        fi
        ;;
    esac
    for property in $properties; do
      value=""
      case "$property" in
        ActiveState)
          if [ "$transition_poll" -eq 1 ]; then
            value=failed
          else
            state_file="{states_dir}/$unit"
            if [ -f "$state_file" ]; then value="$(cat "$state_file")"; else value=active; fi
          fi
          ;;
        SubState)
          if [ "$transition_poll" -eq 1 ]; then value=failed; else value=dead; fi
          ;;
        Result)
          if [ "$transition_poll" -eq 1 ]; then value=signal; else value="${{FAKE_SYSTEMCTL_RESULT:-success}}"; fi
          ;;
        Job)
          if [ "$transition_poll" -eq 1 ]; then value=/org/freedesktop/systemd1/job/1; fi
          ;;
        After) value="pvl-ollama.service pvl-ollama-nvidia.service network-online.target" ;;
      esac
      if [ "$value_only" = true ]; then
        printf '%s\\n' "$value"
      else
        printf '%s=%s\\n' "$property" "$value"
      fi
    done
    ;;
esac
""",
        )

    def set_unit_state(self, unit: str, state: str):
        states_dir = self.state_dir / "unit-states"
        states_dir.mkdir(exist_ok=True)
        (states_dir / unit).write_text(f"{state}\n", encoding="utf-8")

    def write_manifest(self, models):
        self.manifest.write_text(
            json.dumps({"version": 1, "models": models}), encoding="utf-8"
        )

    def read_manifest(self):
        return json.loads(self.manifest.read_text(encoding="utf-8"))

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
                "OLLAMA_URLS": "http://127.0.0.1:11434 http://127.0.0.1:12434",
                "OLLAMA_CURRENT_UNIT": "pvl-ollama-models-pull.service",
                "MODEL_RECONCILER_STATE_FILE": str(self.manifest),
            }
        )
        env.update(overrides)
        return env

    def run_helper(self, *, check=True, models=("nomic-embed-text",), **env_overrides):
        return subprocess.run(
            ["bash", str(self.helper), *models],
            cwd=self.repo_root,
            env=self.helper_env(**env_overrides),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def test_dispatch_restarts_worker_to_apply_latest_policy(self):
        worker = "pvl-ollama-models-pull.service"
        self.set_unit_state(worker, "inactive")
        result = subprocess.run(
            ["bash", str(self.helper), "dispatch", worker, "nomic-embed-text"],
            cwd=self.repo_root,
            env=self.helper_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn(
            f"--user restart --no-block {worker}",
            self.read_log("systemctl.log"),
        )

    def test_dispatch_waits_for_replacement_after_old_worker_is_stopped(self):
        worker = "pvl-ollama-models-pull.service"
        self.set_unit_state(worker, "inactive")
        result = subprocess.run(
            ["bash", str(self.helper), "dispatch", worker, "nomic-embed-text"],
            cwd=self.repo_root,
            env=self.helper_env(FAKE_SYSTEMCTL_RESTART_TRANSITION="1"),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
        self.assertIn("worker completed during dispatch", result.stdout)
        self.assertEqual(self.read_log("sleep.log"), ["1"])

    def test_dispatch_rejects_terminal_replacement_failure(self):
        worker = "pvl-ollama-models-pull.service"
        self.set_unit_state(worker, "failed")
        result = subprocess.run(
            ["bash", str(self.helper), "dispatch", worker, "nomic-embed-text"],
            cwd=self.repo_root,
            env=self.helper_env(FAKE_SYSTEMCTL_RESULT="exit-code"),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("worker failed during dispatch", result.stderr)

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

    def test_missing_model_is_pulled_and_owned(self):
        self.set_unit_state("pvl-ollama.service", "active")
        result = self.run_helper(FAKE_CURL_TAGS_STATUS="0")
        self.assertEqual(result.returncode, 0)
        self.assertIn("/api/pull", "\n".join(self.read_log("curl.log")))
        self.assertEqual(self.read_manifest()["models"], ["nomic-embed-text:latest"])

    def test_existing_required_is_adopted_and_manual_model_is_untouched(self):
        self.set_unit_state("pvl-ollama.service", "active")
        result = self.run_helper(
            FAKE_CURL_TAGS_STATUS="0",
            FAKE_CURL_TAGS_RESPONSE=(
                '{"models":[{"name":"nomic-embed-text:latest"},{"name":"manual:1"}]}'
            ),
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.read_manifest()["models"], ["nomic-embed-text:latest"])
        self.assertNotIn("/api/delete", "\n".join(self.read_log("curl.log")))

    def test_only_owned_model_is_deleted(self):
        self.set_unit_state("pvl-ollama.service", "active")
        self.write_manifest(["old:1"])
        result = self.run_helper(
            FAKE_CURL_TAGS_STATUS="0",
            FAKE_CURL_TAGS_RESPONSE=(
                '{"models":['
                '{"name":"nomic-embed-text:latest"},'
                '{"name":"old:1"},'
                '{"name":"manual:1"}'
                "]}"
            ),
        )
        self.assertEqual(result.returncode, 0)
        curl_log = "\n".join(self.read_log("curl.log"))
        self.assertIn("/api/delete", curl_log)
        self.assertIn("old:1", curl_log)
        self.assertNotIn(
            "manual:1",
            [line for line in self.read_log("curl.log") if "/api/delete" in line],
        )
        self.assertEqual(self.read_manifest()["models"], ["nomic-embed-text:latest"])

    def test_preserved_model_is_relinquished_without_delete(self):
        self.set_unit_state("pvl-ollama.service", "active")
        self.write_manifest(["old:1"])
        result = self.run_helper(
            models=(),
            FAKE_CURL_TAGS_STATUS="0",
            OLLAMA_PRESERVED_MODELS="old:1",
        )
        self.assertEqual(result.returncode, 0)
        self.assertNotIn("/api/delete", "\n".join(self.read_log("curl.log")))
        self.assertFalse(self.manifest.exists())

    def test_legacy_manifest_requests_reconciliation_and_is_imported(self):
        legacy_manifest = self.state_dir / "legacy.json"
        legacy_manifest.write_text(
            json.dumps({"version": 1, "models": ["old:1"]}), encoding="utf-8"
        )
        self.set_unit_state("pvl-ollama.service", "active")
        result = self.run_helper(
            models=(),
            FAKE_CURL_TAGS_STATUS="0",
            MODEL_RECONCILER_LEGACY_STATE_FILE=str(legacy_manifest),
            OLLAMA_PRESERVED_MODELS="old:1",
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("imported ownership manifest", result.stdout)
        self.assertEqual(self.read_manifest()["models"], [])
        self.assertNotIn("/api/delete", "\n".join(self.read_log("curl.log")))

    def test_corrupt_manifest_fails_before_api_mutation(self):
        self.manifest.write_text('{"version":99,"models":[]}', encoding="utf-8")
        result = self.run_helper(check=False, FAKE_CURL_TAGS_STATUS="0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid ownership manifest", result.stderr)
        self.assertEqual(self.read_log("curl.log"), [])

    def test_missing_manifest_never_prunes_observed_inventory(self):
        self.set_unit_state("pvl-ollama.service", "active")
        result = self.run_helper(
            models=(),
            FAKE_CURL_TAGS_STATUS="0",
            FAKE_CURL_TAGS_RESPONSE='{"models":[{"name":"manual:1"}]}',
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.read_log("curl.log"), [])

    def test_failed_pull_does_not_claim_ownership(self):
        self.set_unit_state("pvl-ollama.service", "active")
        result = self.run_helper(
            check=False,
            FAKE_CURL_TAGS_STATUS="0",
            FAKE_CURL_PULL_STATUS="22",
        )
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.manifest.exists())


if __name__ == "__main__":
    unittest.main()
