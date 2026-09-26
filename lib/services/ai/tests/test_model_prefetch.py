import concurrent.futures
import importlib.util
import json
import os
import pathlib
import shutil
import stat
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock


class ModelPrefetchTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.plan = self.root / "plan.json"
        self.script = pathlib.Path(os.environ["AI_MODEL_PREFETCH_LIB"])
        self.cache_preparer = pathlib.Path(
            os.environ["AI_MODEL_PREFETCH_CACHE_PREPARER"]
        )
        self.path_contract = json.loads(
            pathlib.Path(os.environ["AI_STORAGE_PATH_CONTRACT"]).read_text()
        )
        cache_spec = importlib.util.spec_from_file_location(
            "model_prefetch_cache", self.cache_preparer
        )
        self.cache_helper = importlib.util.module_from_spec(cache_spec)
        cache_spec.loader.exec_module(self.cache_helper)
        self.user = subprocess.check_output(["id", "-un"], text=True).strip()
        self.group = subprocess.check_output(["id", "-gn"], text=True).strip()
        self.uid = os.getuid()
        self.gid = os.getgid()
        self.runner = self.root / "ai-model-prefetch-all"
        self.runner.write_text(
            f"""#!{shutil.which("bash")}
set -o errexit
set -o nounset
set -o pipefail
export PATH="{self.bin}:$PATH"
plan="${{AI_MODEL_PREFETCH_PLAN:?}}"
cache_preparer="${{AI_MODEL_PREFETCH_CACHE_PREPARER:?}}"
source "{self.script}"
main "$@"
"""
        )
        self.runner.chmod(0o755)

    def tearDown(self):
        self.temp.cleanup()

    def executable(self, name, body):
        path = self.bin / name
        path.write_text(f"#!{shutil.which('bash')}\nset -Eeuo pipefail\n{body}")
        path.chmod(0o755)
        return path

    def owner(self, name=None, uid=None, group=None, gid=None):
        return {
            "name": name if name is not None else self.user,
            "uid": uid if uid is not None else self.uid,
            "group": group if group is not None else self.group,
            "gid": gid if gid is not None else self.gid,
        }

    def hf_entry(self, cache=None, **overrides):
        entry = {
            "id": "hf:qwen",
            "type": "hf",
            "model": "Qwen/example",
            "revision": None,
            "include": [],
            "cacheDir": str(cache or (self.root / "cache")),
            "tokenFile": None,
            "user": self.user,
            "policy": "required",
        }
        entry.update(overrides)
        return entry

    def ollama_entry(self, **overrides):
        entry = {
            "id": "ollama:test",
            "type": "ollama",
            "model": "test:1",
            "endpoints": ["http://127.0.0.1:1"],
            "user": self.user,
            "policy": "best-effort",
        }
        entry.update(overrides)
        return entry

    def llama_entry(self, **overrides):
        entry = {
            "id": "llama:default:test",
            "type": "llama",
            "model": "repo/model:Q4",
            "endpoints": ["http://127.0.0.1:8080"],
            "user": self.user,
            "policy": "best-effort",
        }
        entry.update(overrides)
        return entry

    def run_raw_plan(self, contents, extra_env=None):
        self.plan.write_text(contents)
        env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "AI_MODEL_PREFETCH_PLAN": str(self.plan),
            **(extra_env or {}),
        }
        return subprocess.run(
            [str(self.runner)],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def run_plan(self, entries, extra_env=None):
        return self.run_raw_plan(json.dumps(entries), extra_env)

    def schema_accepts(self, entry):
        env = {
            **os.environ,
            "AI_MODEL_PREFETCH_LIB": str(self.script),
            "ENTRY": json.dumps(entry),
        }
        return subprocess.run(
            [
                shutil.which("bash"),
                "-c",
                'plan=/dev/null; cache_preparer=; '
                'source "$AI_MODEL_PREFETCH_LIB"; validate_entry "$ENTRY"',
            ],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_huggingface_uses_shared_cache_revision_and_includes(self):
        log = self.root / "hf.log"
        self.executable(
            "hf",
            f'printf "%s\\n%s\\n" "$HF_HOME" "$*" > "{log}"\n',
        )
        cache = self.root / "cache"
        entry = self.hf_entry(
            cache,
            revision="release",
            include=["*.safetensors", "config.json"],
        )
        result = self.run_plan([entry])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(
            [
                str(cache),
                (
                    "download Qwen/example --revision release "
                    "--include *.safetensors --include config.json"
                ),
            ],
            log.read_text().splitlines(),
        )

    def test_missing_huggingface_token_file_fails_before_download(self):
        log = self.root / "hf.log"
        self.executable("hf", f'printf called > "{log}"\n')
        token_file = self.root / "missing-token"
        result = self.run_plan(
            [self.hf_entry(tokenFile=str(token_file))],
        )
        self.assertNotEqual(0, result.returncode)
        self.assertIn("token file is unreadable", result.stderr)
        self.assertFalse((self.root / "cache").exists())
        self.assertFalse(log.exists())

    def test_huggingface_token_is_environment_only(self):
        log = self.root / "hf.log"
        token_file = self.root / "token"
        token_file.write_text("fixture-secret\n")
        self.executable(
            "hf",
            '[[ "${HF_TOKEN:-}" == "fixture-secret" ]] || exit 70\n'
            '[[ -z "${HUGGING_FACE_HUB_TOKEN+x}" ]] || exit 72\n'
            '[[ "$*" != *"fixture-secret"* ]] || exit 71\n'
            f'printf called > "{log}"\n',
        )
        result = self.run_plan(
            [self.hf_entry(tokenFile=str(token_file))],
            {
                "HF_TOKEN": "ambient-token",
                "HUGGING_FACE_HUB_TOKEN": "legacy-ambient-token",
            },
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(log.exists())

    def test_huggingface_without_token_file_clears_ambient_tokens(self):
        log = self.root / "hf.log"
        self.executable(
            "hf",
            '[[ -z "${HF_TOKEN+x}" ]] || exit 70\n'
            '[[ -z "${HUGGING_FACE_HUB_TOKEN+x}" ]] || exit 71\n'
            f'printf called > "{log}"\n',
        )
        result = self.run_plan(
            [self.hf_entry()],
            {
                "HF_TOKEN": "ambient-token",
                "HUGGING_FACE_HUB_TOKEN": "legacy-ambient-token",
            },
        )
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(log.exists())

    def test_huggingface_token_must_be_one_non_empty_whitespace_free_line(self):
        self.executable("hf", "exit 70\n")
        for contents in ("", "first\nsecond\n", "first\n\n", "with space\n", "crlf\r\n"):
            with self.subTest(contents=repr(contents)):
                token_file = self.root / "token"
                token_file.write_text(contents)
                result = self.run_plan(
                    [self.hf_entry(tokenFile=str(token_file))],
                )
                self.assertNotEqual(0, result.returncode)
                self.assertIn("exactly one non-empty whitespace-free line", result.stderr)

    def test_all_required_tokens_are_validated_before_cache_creation(self):
        first_cache = self.root / "first-cache"
        log = self.root / "hf.log"
        token_file = self.root / "bad-token"
        token_file.write_text("first\nsecond\n")
        self.executable("hf", f'printf called > "{log}"\n')
        second = self.hf_entry(
            self.root / "second-cache",
            id="hf:second",
            tokenFile=str(token_file),
        )
        result = self.run_plan([self.hf_entry(first_cache), second])
        self.assertNotEqual(0, result.returncode)
        self.assertIn("exactly one non-empty whitespace-free line", result.stderr)
        self.assertFalse(first_cache.exists())
        self.assertFalse(log.exists())

    def test_required_huggingface_failure_blocks(self):
        self.executable("hf", "exit 7\n")
        result = self.run_plan([self.hf_entry()])
        self.assertNotEqual(0, result.returncode)
        self.assertIn("required prefetch failed", result.stderr)

    def test_required_huggingface_has_finite_configurable_deadline(self):
        self.executable("hf", "exec sleep 5\n")
        started = time.monotonic()
        result = self.run_plan(
            [self.hf_entry()], {"AI_MODEL_PREFETCH_HF_TIMEOUT_SECONDS": "1"}
        )
        elapsed = time.monotonic() - started
        self.assertNotEqual(0, result.returncode)
        self.assertLess(elapsed, 3, result.stderr)

    def test_required_huggingface_entries_share_one_total_deadline(self):
        log = self.root / "hf.log"
        self.executable(
            "hf",
            f'printf "%s\\n" called >> "{log}"\nexec sleep 5\n',
        )
        second = self.hf_entry(self.root / "second-cache", id="hf:second")
        started = time.monotonic()
        result = self.run_plan(
            [self.hf_entry(), second],
            {"AI_MODEL_PREFETCH_HF_TIMEOUT_SECONDS": "2"},
        )
        elapsed = time.monotonic() - started
        self.assertNotEqual(0, result.returncode)
        self.assertLess(elapsed, 4, result.stderr)
        self.assertEqual(["called"], log.read_text().splitlines())

    def test_ollama_pull_uses_first_successful_json_endpoint(self):
        log = self.root / "curl.log"
        self.executable(
            "curl",
            f'printf "%s\\n" "$*" >> "{log}"\n'
            'if [[ "$*" == *"127.0.0.1:1"* ]]; then exit 7; fi\n'
            "printf '%s\\n' '{\"status\":\"success\"}'\n",
        )
        entry = self.ollama_entry(
            endpoints=["http://127.0.0.1:1", "http://127.0.0.1:2"]
        )
        result = self.run_plan([entry])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("127.0.0.1:2/api/pull", log.read_text())

    def test_unreachable_best_effort_backend_does_not_block(self):
        self.executable("curl", "exit 7\n")
        result = self.run_plan([self.ollama_entry()])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("best-effort prefetch deferred", result.stderr)

    def test_one_global_best_effort_budget_bounds_http(self):
        self.executable("curl", "exec sleep 5\n")
        started = time.monotonic()
        result = self.run_plan(
            [self.ollama_entry(), self.ollama_entry(id="ollama:second")],
            {"AI_MODEL_PREFETCH_BEST_EFFORT_SECONDS": "1"},
        )
        elapsed = time.monotonic() - started
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertLess(elapsed, 3, result.stderr)
        self.assertEqual(2, result.stderr.count("best-effort prefetch deferred"))

    def test_invalid_ollama_api_json_is_deferred(self):
        self.executable("curl", "printf 'not-json\\n'\n")
        result = self.run_plan([self.ollama_entry()])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("best-effort prefetch deferred", result.stderr)

    def test_llama_cached_model_needs_no_download(self):
        log = self.root / "curl.log"
        self.executable(
            "curl",
            f'printf "%s\\n" "$*" >> "{log}"\n'
            "printf '%s\\n' "
            '\'{"data":[{"id":"repo/model:Q4",'
            '"status":{"value":"unloaded"}}]}\'\n',
        )
        result = self.run_plan([self.llama_entry()])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn("--request POST", log.read_text())

    def test_llama_absent_model_returns_after_accepted_post(self):
        log = self.root / "curl.log"
        self.executable(
            "curl",
            f'printf "%s\\n" "$*" >> "{log}"\n'
            'if [[ "$*" == *"--request POST"* ]]; then\n'
            "  printf '%s\\n' '{\"accepted\":true}'\n"
            "else\n"
            "  printf '%s\\n' '{\"data\":[]}'\n"
            "fi\n",
        )
        started = time.monotonic()
        result = self.run_plan([self.llama_entry()])
        elapsed = time.monotonic() - started
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertLess(elapsed, 2, result.stderr)
        self.assertEqual(2, len(log.read_text().splitlines()))
        self.assertIn("--request POST", log.read_text())

    def test_llama_post_error_object_is_deferred(self):
        self.executable(
            "curl",
            'if [[ "$*" == *"--request POST"* ]]; then\n'
            "  printf '%s\\n' '{\"error\":\"download rejected\"}'\n"
            "else\n"
            "  printf '%s\\n' '{\"data\":[]}'\n"
            "fi\n",
        )
        result = self.run_plan([self.llama_entry()])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("best-effort prefetch deferred", result.stderr)

    def test_invalid_llama_api_json_is_deferred_without_post(self):
        log = self.root / "curl.log"
        self.executable(
            "curl",
            f'printf "%s\\n" "$*" >> "{log}"\nprintf \'not-json\\n\'\n',
        )
        result = self.run_plan([self.llama_entry()])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("best-effort prefetch deferred", result.stderr)
        self.assertNotIn("--request POST", log.read_text())

    def test_whole_plan_schema_is_validated_before_mutation(self):
        log = self.root / "hf.log"
        self.executable("hf", f'printf called > "{log}"\n')
        cache = self.root / "cache"
        invalid = self.hf_entry(self.root / "other-cache", include="*.bin")
        result = self.run_plan([self.hf_entry(cache), invalid])
        self.assertNotEqual(0, result.returncode)
        self.assertIn("violates its schema", result.stderr)
        self.assertFalse(cache.exists())
        self.assertFalse(log.exists())

    def test_storage_path_contract_matches_schema_and_cache_helper(self):
        for valid_path in self.path_contract["valid"]:
            with self.subTest(valid=repr(valid_path)):
                self.assertEqual(
                    0,
                    self.schema_accepts(self.hf_entry(cache=valid_path)).returncode,
                )
                self.assertEqual(
                    tuple(pathlib.PurePosixPath(valid_path).parts[1:]),
                    tuple(self.cache_helper.path_components(valid_path)),
                )

        for unsafe_path in self.path_contract["invalid"]:
            with self.subTest(cache=unsafe_path):
                self.assertNotEqual(
                    0,
                    self.schema_accepts(self.hf_entry(cache=unsafe_path)).returncode,
                )
                with self.assertRaises(RuntimeError):
                    self.cache_helper.path_components(unsafe_path)
            with self.subTest(token=unsafe_path):
                self.assertNotEqual(
                    0,
                    self.schema_accepts(
                        self.hf_entry(tokenFile=unsafe_path),
                    ).returncode,
                )

    def test_malformed_json_fails_instead_of_becoming_an_empty_plan(self):
        result = self.run_raw_plan("{")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("violates its schema", result.stderr)

    def test_empty_or_non_http_endpoints_fail_schema(self):
        for endpoints in ([], ["file:///tmp/socket"], "http://127.0.0.1:1"):
            with self.subTest(endpoints=endpoints):
                result = self.run_plan([self.ollama_entry(endpoints=endpoints)])
                self.assertNotEqual(0, result.returncode)
                self.assertIn("violates its schema", result.stderr)

    def test_numeric_owner_prepares_exact_cache_leaf(self):
        log = self.root / "hf.log"
        self.executable("hf", f'printf called > "{log}"\n')
        cache = self.root / "cache"
        entry = self.hf_entry(cache, owner=self.owner())
        entry.pop("user")
        result = self.run_plan([entry])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(cache.is_dir())
        self.assertEqual(
            (self.uid, self.gid), (cache.stat().st_uid, cache.stat().st_gid)
        )
        self.assertEqual(0o750, cache.stat().st_mode & 0o777)
        self.assertTrue(log.exists())

    def test_numeric_candidate_owner_does_not_require_current_passwd_entry(self):
        log = self.root / "setpriv.log"
        hf_log = self.root / "hf.log"
        cache = self.root / "cache"
        cache.mkdir()
        cache.chmod(0o750)
        self.executable(
            "id",
            'case "${1:-}" in\n'
            "  -u) printf '0\\n' ;;\n"
            "  -g) printf '0\\n' ;;\n"
            "  -un) printf 'root\\n' ;;\n"
            "  *) exit 2 ;;\n"
            "esac\n",
        )
        self.executable("getent", "exit 2\n")
        self.executable(
            "setpriv",
            f'printf "%s\\n" "$*" > "{log}"\n'
            "while (( $# > 0 )); do\n"
            '  if [[ "$1" == -- ]]; then shift; exec "$@"; fi\n'
            "  shift\n"
            "done\n"
            "exit 2\n",
        )
        self.executable("hf", f'printf called > "{hf_log}"\n')
        entry = self.hf_entry(
            cache,
            owner=self.owner(name="candidate-owner"),
        )
        entry.pop("user")
        result = self.run_plan([entry])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn(f"--reuid={self.uid}", log.read_text())
        self.assertIn(f"--regid={self.gid}", log.read_text())
        self.assertIn(f"HOME={cache}", log.read_text())
        self.assertIn(f"HF_HOME={cache}", log.read_text())
        self.assertIn("USER=candidate-owner", log.read_text())
        self.assertIn("LOGNAME=candidate-owner", log.read_text())
        self.assertTrue(hf_log.exists())

    def test_existing_cache_ownership_conflict_is_refused(self):
        cache = self.root / "cache"
        cache.mkdir()
        self.executable(
            "id",
            'case "${1:-}" in\n'
            "  -u) printf '0\\n' ;;\n"
            "  -g) printf '0\\n' ;;\n"
            "  -un) printf 'root\\n' ;;\n"
            "  *) exit 2 ;;\n"
            "esac\n",
        )
        self.executable("getent", "exit 2\n")
        entry = self.hf_entry(
            cache,
            owner=self.owner(name="candidate-owner", uid=self.uid + 100000),
        )
        entry.pop("user")
        result = self.run_plan([entry])
        self.assertNotEqual(0, result.returncode)
        self.assertIn("ownership conflict", result.stderr)

    def test_candidate_owner_gid_collision_is_refused(self):
        cache = self.root / "cache"
        candidate_gid = self.gid + 100000
        self.executable(
            "id",
            'case "${1:-}" in\n'
            "  -u) printf '0\\n' ;;\n"
            "  -g) printf '0\\n' ;;\n"
            "  -un) printf 'root\\n' ;;\n"
            "  *) exit 2 ;;\n"
            "esac\n",
        )
        self.executable(
            "getent",
            'if [[ "$1" == group && "$2" == "'
            f'{candidate_gid}" ]]; then\n'
            f"  printf 'unrelated:x:{candidate_gid}:\\n'\n"
            "  exit 0\n"
            "fi\n"
            "exit 2\n",
        )
        entry = self.hf_entry(
            cache,
            owner=self.owner(
                name="candidate-owner",
                uid=self.uid + 100000,
                group="candidate-group",
                gid=candidate_gid,
            ),
        )
        entry.pop("user")
        result = self.run_plan([entry])
        self.assertNotEqual(0, result.returncode)
        self.assertIn("GID conflicts", result.stderr)
        self.assertFalse(cache.exists())

    def test_all_required_identities_are_validated_before_cache_creation(self):
        first_cache = self.root / "first-cache"
        second_uid = self.uid + 100000
        self.executable(
            "id",
            'case "${1:-}" in\n'
            "  -u) printf '0\\n' ;;\n"
            "  -g) printf '0\\n' ;;\n"
            "  -un) printf 'root\\n' ;;\n"
            "  *) exit 2 ;;\n"
            "esac\n",
        )
        self.executable(
            "getent",
            'if [[ "$1" == passwd && "$2" == "'
            f'{second_uid}" ]]; then\n'
            f"  printf 'unrelated:x:{second_uid}:{self.gid}:/nonexistent:/bin/false\\n'\n"
            "  exit 0\n"
            "fi\n"
            "exit 2\n",
        )
        first = self.hf_entry(first_cache, owner=self.owner())
        first.pop("user")
        second = self.hf_entry(
            self.root / "second-cache",
            id="hf:second",
            owner=self.owner(name="candidate-owner", uid=second_uid),
        )
        second.pop("user")
        result = self.run_plan([first, second])
        self.assertNotEqual(0, result.returncode)
        self.assertIn("UID conflicts", result.stderr)
        self.assertFalse(first_cache.exists())

    def test_cache_preparer_creates_missing_parent_without_privileged_shell_writes(self):
        self.executable("hf", "exit 0\n")
        cache = self.root / "missing-parent" / "cache"
        result = self.run_plan([self.hf_entry(cache)])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(cache.is_dir())
        self.assertNotIn("mkdir -m", self.script.read_text())
        self.assertNotIn("install -d", self.script.read_text())

    def test_cache_leaf_is_fully_initialized_before_atomic_publication(self):
        parent = self.root / "parent"
        parent.mkdir()
        parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        observed = []
        staging_modes = []
        original_rename = self.cache_helper.rename_noreplace

        def inspect_then_rename(
            source_directory_fd,
            source,
            destination_directory_fd,
            destination,
        ):
            staging_modes.append(
                stat.S_IMODE(os.fstat(source_directory_fd).st_mode)
            )
            source_fd = self.cache_helper.open_directory(source_directory_fd, source)
            try:
                source_stat = os.fstat(source_fd)
                observed.append(
                    (
                        source_stat.st_uid,
                        source_stat.st_gid,
                        stat.S_IMODE(source_stat.st_mode),
                    )
                )
            finally:
                os.close(source_fd)
            original_rename(
                source_directory_fd,
                source,
                destination_directory_fd,
                destination,
            )

        try:
            with mock.patch.object(
                self.cache_helper,
                "rename_noreplace",
                inspect_then_rename,
            ):
                cache_fd, created = self.cache_helper.create_directory(
                    parent_fd,
                    "cache",
                    0o750,
                    (self.uid, self.gid),
                )
            os.close(cache_fd)
        finally:
            os.close(parent_fd)

        self.assertTrue(created)
        self.assertEqual([0o700], staging_modes)
        self.assertEqual([(self.uid, self.gid, 0o750)], observed)

    def test_concurrent_cache_creators_observe_only_final_leaf_state(self):
        parent = self.root / "parent"
        parent.mkdir()
        barrier = threading.Barrier(2)
        original_rename = self.cache_helper.rename_noreplace

        def synchronized_rename(
            source_directory_fd,
            source,
            destination_directory_fd,
            destination,
        ):
            barrier.wait(timeout=5)
            original_rename(
                source_directory_fd,
                source,
                destination_directory_fd,
                destination,
            )

        def create():
            parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                cache_fd, created = self.cache_helper.create_directory(
                    parent_fd,
                    "cache",
                    0o750,
                    (self.uid, self.gid),
                )
                try:
                    cache_stat = os.fstat(cache_fd)
                    return created, (
                        cache_stat.st_uid,
                        cache_stat.st_gid,
                        stat.S_IMODE(cache_stat.st_mode),
                    )
                finally:
                    os.close(cache_fd)
            finally:
                os.close(parent_fd)

        with mock.patch.object(
            self.cache_helper,
            "rename_noreplace",
            synchronized_rename,
        ):
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
                results = list(executor.map(lambda _index: create(), range(2)))

        self.assertEqual([False, True], sorted(created for created, _state in results))
        self.assertEqual(
            [(self.uid, self.gid, 0o750), (self.uid, self.gid, 0o750)],
            [state for _created, state in results],
        )

    def test_root_prepares_missing_parent_chain_without_passwd_owner(self):
        hf_log = self.root / "hf.log"
        cache = self.root / "new" / "nested" / "cache"
        self.executable(
            "id",
            'case "${1:-}" in\n'
            "  -u) printf '0\\n' ;;\n"
            "  -g) printf '0\\n' ;;\n"
            "  -un) printf 'root\\n' ;;\n"
            "  *) exit 2 ;;\n"
            "esac\n",
        )
        self.executable("getent", "exit 2\n")
        self.executable(
            "setpriv",
            "while (( $# > 0 )); do\n"
            '  if [[ "$1" == -- ]]; then shift; exec "$@"; fi\n'
            "  shift\n"
            "done\n"
            "exit 2\n",
        )
        self.executable("hf", f'printf called > "{hf_log}"\n')
        entry = self.hf_entry(
            cache,
            owner=self.owner(name="candidate-owner"),
        )
        entry.pop("user")
        result = self.run_plan([entry])
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(cache.is_dir())
        self.assertTrue(hf_log.exists())

    def test_symbolic_link_in_cache_parent_is_refused(self):
        target = self.root / "target"
        target.mkdir()
        linked = self.root / "linked"
        linked.symlink_to(target, target_is_directory=True)
        result = self.run_plan([self.hf_entry(linked / "cache")])
        self.assertNotEqual(0, result.returncode)
        self.assertIn("ai-model-prefetch-cache", result.stderr)
        self.assertFalse((target / "cache").exists())

    def test_existing_cache_mode_conflict_is_refused_without_repair(self):
        cache = self.root / "cache"
        cache.mkdir(mode=0o755)
        result = self.run_plan([self.hf_entry(cache)])
        self.assertNotEqual(0, result.returncode)
        self.assertIn("mode conflict", result.stderr)
        self.assertEqual(0o755, cache.stat().st_mode & 0o777)

    def test_runner_has_no_fallible_process_substitution(self):
        self.assertNotIn("< <(", self.script.read_text())


if __name__ == "__main__":
    unittest.main()
