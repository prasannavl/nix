import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


class LlamaRouterHelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[4]
        cls.helper = cls.repo_root / "lib/services/llama-router/helper.sh"
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def setUp(self):
        self.work_dir = Path(
            tempfile.mkdtemp(prefix="llama-router-helper-test.", dir=self.tmp_root)
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
        download_marker = self.state_dir / "download-requested"
        self.write_executable(
            self.fake_bin / "curl",
            f"""#!/bin/sh
printf '%s\\n' "$*" >> {log_path}
url=""
for arg in "$@"; do
  url="$arg"
done
case "$url" in
  */models)
    case " $* " in
      *" -X POST "*)
        if [ "${{FAKE_CURL_DOWNLOAD_STATUS:-0}}" != 0 ]; then
          exit "$FAKE_CURL_DOWNLOAD_STATUS"
        fi
        touch {download_marker}
        printf '%s\\n' '{{"success":true}}'
        ;;
      *" -X DELETE "*)
        if [ "${{FAKE_CURL_DELETE_STATUS:-0}}" != 0 ]; then
          exit "$FAKE_CURL_DELETE_STATUS"
        fi
        printf '%s\\n' '{{"success":true}}'
        ;;
      *)
        if [ "${{FAKE_CURL_MODELS_STATUS:-7}}" != 0 ]; then
          exit "$FAKE_CURL_MODELS_STATUS"
        fi
        if [ -n "${{FAKE_CURL_MODELS_RESPONSE+x}}" ]; then
          printf '%s\\n' "$FAKE_CURL_MODELS_RESPONSE"
        elif [ -f {download_marker} ]; then
          printf '%s\\n' '{{"data":[{{"id":"test/model:Q4_K_M","status":{{"value":"unloaded","args":[]}}}}]}}'
        else
          printf '%s\\n' '{{"data":[]}}'
        fi
        ;;
    esac
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
        state_file="{states_dir}/$unit"
        if [ -f "$state_file" ]; then cat "$state_file"; else printf '%s\\n' active; fi
        ;;
      SubState) printf '%s\\n' dead ;;
      Result) printf '%s\\n' success ;;
      After)
        printf '%s\\n' "pvl-llama-router.service network-online.target"
        ;;
    esac
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
                "LLAMA_ROUTER_URLS": "http://127.0.0.1:11434 http://127.0.0.1:11435",
                "LLAMA_ROUTER_CURRENT_UNIT": "pvl-llama-router-models-load.service",
                "MODEL_RECONCILER_STATE_FILE": str(self.manifest),
            }
        )
        env.update(overrides)
        return env

    def run_helper(self, *, check=True, models=("test/model:Q4_K_M",), **env_overrides):
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
        worker = "pvl-llama-router-models-load.service"
        self.set_unit_state(worker, "inactive")
        result = subprocess.run(
            ["bash", str(self.helper), "dispatch", worker, "test/model:Q4_K_M"],
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

    def test_skip_if_configured_backends_are_inactive(self):
        self.set_unit_state("pvl-llama-router.service", "inactive")
        result = self.run_helper(
            LLAMA_ROUTER_WAIT_ATTEMPTS="120",
            LLAMA_ROUTER_WAIT_DELAY_SECONDS="60",
            FAKE_SLEEP_STATUS="99",
        )
        self.assertEqual(result.returncode, 0)
        self.assertIn("dependent service units are inactive", result.stderr)
        self.assertEqual(self.read_log("sleep.log"), [])

    def test_missing_model_is_downloaded_lazily_and_owned(self):
        self.set_unit_state("pvl-llama-router.service", "active")
        result = self.run_helper(FAKE_CURL_MODELS_STATUS="0")
        self.assertEqual(result.returncode, 0)
        curl_log = "\n".join(self.read_log("curl.log"))
        self.assertIn("-X POST", curl_log)
        self.assertNotIn("/models/load", curl_log)
        self.assertEqual(self.read_manifest()["models"], ["test/model:Q4_K_M"])

    def test_existing_required_is_adopted_and_manual_model_is_untouched(self):
        self.set_unit_state("pvl-llama-router.service", "active")
        result = self.run_helper(
            FAKE_CURL_MODELS_STATUS="0",
            FAKE_CURL_MODELS_RESPONSE=(
                '{"data":['
                '{"id":"test/model:Q4_K_M","status":{"value":"unloaded","args":[]}},'
                '{"id":"manual/model:Q8_0","status":{"value":"unloaded","args":[]}}'
                "]}"
            ),
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.read_manifest()["models"], ["test/model:Q4_K_M"])
        self.assertNotIn("-X DELETE", "\n".join(self.read_log("curl.log")))

    def test_only_exact_owned_quant_is_deleted(self):
        self.set_unit_state("pvl-llama-router.service", "active")
        self.write_manifest(["same/repo:Q8_0"])
        result = self.run_helper(
            models=("same/repo:Q4_K_M",),
            FAKE_CURL_MODELS_STATUS="0",
            FAKE_CURL_MODELS_RESPONSE=(
                '{"data":['
                '{"id":"same/repo:Q4_K_M","status":{"value":"unloaded","args":[]}},'
                '{"id":"same/repo:Q8_0","status":{"value":"unloaded","args":[]}}'
                "]}"
            ),
        )
        self.assertEqual(result.returncode, 0)
        curl_log = "\n".join(self.read_log("curl.log"))
        self.assertIn("--data-urlencode model=same/repo:Q8_0", curl_log)
        self.assertNotIn("--data-urlencode model=same/repo:Q4_K_M", curl_log)
        self.assertEqual(self.read_manifest()["models"], ["same/repo:Q4_K_M"])

    def test_preserved_model_is_relinquished_without_delete(self):
        self.set_unit_state("pvl-llama-router.service", "active")
        self.write_manifest(["old/model:Q4_K_M"])
        result = self.run_helper(
            models=(),
            FAKE_CURL_MODELS_STATUS="0",
            LLAMA_ROUTER_PRESERVED_MODELS="old/model:Q4_K_M",
        )
        self.assertEqual(result.returncode, 0)
        self.assertNotIn("-X DELETE", "\n".join(self.read_log("curl.log")))
        self.assertEqual(self.read_manifest()["models"], [])

    def test_corrupt_manifest_fails_before_api_mutation(self):
        self.manifest.write_text('{"version":99,"models":[]}', encoding="utf-8")
        result = self.run_helper(check=False, FAKE_CURL_MODELS_STATUS="0")
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid ownership manifest", result.stderr)
        self.assertEqual(self.read_log("curl.log"), [])

    def test_missing_manifest_never_prunes_observed_inventory(self):
        self.set_unit_state("pvl-llama-router.service", "active")
        result = self.run_helper(
            models=(),
            FAKE_CURL_MODELS_STATUS="0",
            FAKE_CURL_MODELS_RESPONSE=(
                '{"data":[{"id":"manual/model:Q4_K_M",'
                '"status":{"value":"unloaded","args":[]}}]}'
            ),
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.read_log("curl.log"), [])

    def test_failed_download_does_not_claim_ownership(self):
        self.set_unit_state("pvl-llama-router.service", "active")
        result = self.run_helper(
            check=False,
            FAKE_CURL_MODELS_STATUS="0",
            FAKE_CURL_DOWNLOAD_STATUS="22",
        )
        self.assertEqual(result.returncode, 1)
        self.assertFalse(self.manifest.exists())


if __name__ == "__main__":
    unittest.main()
