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
        self.work_dir = Path(tempfile.mkdtemp(prefix="llama-router-helper-test.", dir=self.tmp_root))
        self.fake_bin = self.work_dir / "bin"
        self.state_dir = self.work_dir / "state"
        self.cache_dir = self.work_dir / "cache"
        self.fake_bin.mkdir()
        self.state_dir.mkdir()
        self.cache_dir.mkdir()
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
        load_marker = self.state_dir / "load-requested"
        self.write_executable(
            self.fake_bin / "curl",
            f"""#!/bin/sh
printf '%s\\n' "$*" >> {log_path}
url=""
for arg in "$@"; do
  url="$arg"
done
case "$url" in
  */models?reload=1)
    if [ "${{FAKE_CURL_MODELS_STATUS:-7}}" != 0 ]; then
      exit "$FAKE_CURL_MODELS_STATUS"
    fi
    printf '%s\\n' '{{"data":[]}}'
    ;;
  */models)
    if [ "${{FAKE_CURL_MODELS_STATUS:-7}}" != 0 ]; then
      exit "$FAKE_CURL_MODELS_STATUS"
    fi
    if [ -n "${{FAKE_CURL_MODELS_RESPONSE+x}}" ]; then
      printf '%s\\n' "$FAKE_CURL_MODELS_RESPONSE"
    elif [ -f {load_marker} ]; then
      printf '%s\\n' '{{"data":[{{"id":"test/model:Q4_K_M","status":{{"value":"loaded","args":[]}}}}]}}'
    else
      printf '%s\\n' '{{"data":[{{"id":"test/model:Q4_K_M","status":{{"value":"unloaded","args":[]}}}}]}}'
    fi
    ;;
  */models/load)
    if [ "${{FAKE_CURL_LOAD_STATUS:-0}}" != 0 ]; then
      exit "$FAKE_CURL_LOAD_STATUS"
    fi
    touch {load_marker}
    printf '%s\\n' '{{"success":true}}'
    ;;
  */models/unload)
    if [ "${{FAKE_CURL_UNLOAD_STATUS:-0}}" != 0 ]; then
      exit "$FAKE_CURL_UNLOAD_STATUS"
    fi
    printf '%s\\n' '{{"success":true}}'
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
          pvl-llama-router-models-load.service)
            printf '%s\\n' "pvl-llama-router.service network-online.target"
            ;;
        esac
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

    def write_model_cache(self, repo_dir: str):
        snapshot_dir = self.cache_dir / repo_dir / "snapshots" / "revision"
        snapshot_dir.mkdir(parents=True)
        (snapshot_dir / "weights.gguf").write_text("weights\n", encoding="utf-8")

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
                "LLAMA_ROUTER_CACHE_DIR": str(self.cache_dir),
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
        self.assertEqual(len(self.read_log("curl.log")), 2)

    def test_active_backend_keeps_normal_wait_path(self):
        self.set_unit_state("pvl-llama-router.service", "active")

        result = self.run_helper(
            check=False,
            LLAMA_ROUTER_WAIT_ATTEMPTS="2",
            LLAMA_ROUTER_WAIT_DELAY_SECONDS="0",
        )

        self.assertEqual(result.returncode, 1)
        self.assertNotIn("dependent service units are inactive", result.stderr)
        self.assertIn("no llama-router API available", result.stderr)
        self.assertEqual(len(self.read_log("curl.log")), 4)
        self.assertEqual(self.read_log("sleep.log"), ["0"])

    def test_loaded_model_is_left_alone(self):
        self.set_unit_state("pvl-llama-router.service", "active")

        result = self.run_helper(
            FAKE_CURL_MODELS_STATUS="0",
            FAKE_CURL_MODELS_RESPONSE=(
                '{"data":['
                '{"id":"test/model:Q4_K_M","status":{"value":"loaded","args":[]}}'
                "]}"
            ),
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn("already loaded", result.stdout)
        curl_log = "\n".join(self.read_log("curl.log"))
        self.assertNotIn("/models/load", curl_log)
        self.assertNotIn("/models?reload=1", curl_log)

    def test_unloaded_model_is_downloaded_and_loaded(self):
        self.set_unit_state("pvl-llama-router.service", "active")

        result = self.run_helper(FAKE_CURL_MODELS_STATUS="0")

        self.assertEqual(result.returncode, 0)
        self.assertIn("model test/model:Q4_K_M is loaded", result.stdout)
        curl_log = "\n".join(self.read_log("curl.log"))
        self.assertIn("/models/load", curl_log)
        self.assertNotIn("/models?reload=1", curl_log)

    def test_failed_load_with_cached_weights_warns(self):
        self.set_unit_state("pvl-llama-router.service", "active")
        self.write_model_cache("models--test--model")

        result = self.run_helper(
            FAKE_CURL_MODELS_STATUS="0",
            FAKE_CURL_MODELS_RESPONSE=(
                '{"data":['
                '{"id":"test/model:Q4_K_M","status":{"value":"unloaded","args":[],"exit_code":1,"failed":true}}'
                "]}"
            ),
        )

        self.assertEqual(result.returncode, 0)
        self.assertIn("failed to load despite cached weights", result.stderr)

    def test_failed_load_without_cached_weights_fails(self):
        self.set_unit_state("pvl-llama-router.service", "active")

        result = self.run_helper(
            check=False,
            FAKE_CURL_MODELS_STATUS="0",
            FAKE_CURL_MODELS_RESPONSE=(
                '{"data":['
                '{"id":"test/model:Q4_K_M","status":{"value":"unloaded","args":[],"exit_code":1,"failed":true}}'
                "]}"
            ),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("has no cached weights", result.stderr)

    def test_failed_load_request_fails(self):
        self.set_unit_state("pvl-llama-router.service", "active")

        result = self.run_helper(
            check=False,
            FAKE_CURL_MODELS_STATUS="0",
            FAKE_CURL_LOAD_STATUS="22",
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("failed to request load", result.stderr)

    def test_retired_model_is_unloaded_pruned_and_reloaded(self):
        self.set_unit_state("pvl-llama-router.service", "active")
        self.write_model_cache("models--test--model")
        self.write_model_cache("models--old--model")

        result = self.run_helper(
            FAKE_CURL_MODELS_STATUS="0",
            FAKE_CURL_MODELS_RESPONSE=(
                '{"data":['
                '{"id":"test/model:Q4_K_M","status":{"value":"loaded","args":[]}},'
                '{"id":"old/model:Q4_K_M","status":{"value":"loaded","args":[]}}'
                "]}"
            ),
            LLAMA_ROUTER_RETIRED_MODELS="old/model:Q4_K_M",
        )

        self.assertEqual(result.returncode, 0)
        curl_log = "\n".join(self.read_log("curl.log"))
        self.assertIn("/models/unload", curl_log)
        self.assertIn("/models?reload=1", curl_log)
        self.assertIn("pruning cache for model old/model:Q4_K_M", result.stdout)
        self.assertFalse((self.cache_dir / "models--old--model").exists())
        self.assertTrue((self.cache_dir / "models--test--model").exists())

    def test_absent_retired_model_prunes_cache_without_unload(self):
        self.set_unit_state("pvl-llama-router.service", "active")
        self.write_model_cache("models--old--model")

        result = self.run_helper(
            FAKE_CURL_MODELS_STATUS="0",
            FAKE_CURL_MODELS_RESPONSE=(
                '{"data":['
                '{"id":"test/model:Q4_K_M","status":{"value":"loaded","args":[]}}'
                "]}"
            ),
            LLAMA_ROUTER_RETIRED_MODELS="old/model:Q4_K_M",
        )

        self.assertEqual(result.returncode, 0)
        curl_log = "\n".join(self.read_log("curl.log"))
        self.assertNotIn("/models/unload", curl_log)
        self.assertIn("/models?reload=1", curl_log)
        self.assertFalse((self.cache_dir / "models--old--model").exists())

    def test_model_cannot_be_both_required_and_retired(self):
        self.set_unit_state("pvl-llama-router.service", "active")

        result = self.run_helper(
            check=False,
            FAKE_CURL_MODELS_STATUS="0",
            FAKE_CURL_MODELS_RESPONSE=(
                '{"data":['
                '{"id":"test/model:Q4_K_M","status":{"value":"loaded","args":[]}}'
                "]}"
            ),
            LLAMA_ROUTER_RETIRED_MODELS="test/model:Q4_K_M",
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("cannot be both required and retired", result.stderr)
        curl_log = "\n".join(self.read_log("curl.log"))
        self.assertNotIn("/models/load", curl_log)
        self.assertNotIn("/models/unload", curl_log)

    def test_invalid_retired_model_ref_is_rejected(self):
        self.set_unit_state("pvl-llama-router.service", "active")

        result = self.run_helper(
            check=False,
            FAKE_CURL_MODELS_STATUS="0",
            LLAMA_ROUTER_RETIRED_MODELS="not-a-ref",
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("not a valid org/repo[:tag] Hugging Face reference", result.stderr)
        curl_log = "\n".join(self.read_log("curl.log"))
        self.assertNotIn("/models/load", curl_log)

    def test_invalid_required_model_ref_is_rejected(self):
        self.set_unit_state("pvl-llama-router.service", "active")

        result = self.run_helper(
            check=False,
            FAKE_CURL_MODELS_STATUS="0",
            models=("not-a-ref",),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("not a valid org/repo[:tag] Hugging Face reference", result.stderr)
        curl_log = "\n".join(self.read_log("curl.log"))
        self.assertNotIn("/models/load", curl_log)

    def test_absent_required_model_fails(self):
        self.set_unit_state("pvl-llama-router.service", "active")

        result = self.run_helper(
            check=False,
            FAKE_CURL_MODELS_STATUS="0",
            FAKE_CURL_MODELS_RESPONSE='{"data":[]}',
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected router status 'absent' for required model", result.stderr)

    def test_no_models_configured_is_noop(self):
        self.set_unit_state("pvl-llama-router.service", "active")

        result = self.run_helper(models=())

        self.assertEqual(result.returncode, 0)
        self.assertIn("no required or retired models configured", result.stdout)
        self.assertEqual(self.read_log("curl.log"), [])

    def test_missing_cache_dir_fails(self):
        self.set_unit_state("pvl-llama-router.service", "active")

        result = self.run_helper(
            check=False,
            FAKE_CURL_MODELS_STATUS="0",
            LLAMA_ROUTER_CACHE_DIR="",
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("LLAMA_ROUTER_CACHE_DIR is required", result.stderr)
        curl_log = "\n".join(self.read_log("curl.log"))
        self.assertNotIn("/models/load", curl_log)


if __name__ == "__main__":
    unittest.main()