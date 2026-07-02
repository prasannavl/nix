import json
import os
import stat
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


class PodmanComposeHelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[3]
        cls.helper = cls.repo_root / "lib/podman-compose/helper.sh"
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def setUp(self):
        self.work_dir = Path(tempfile.mkdtemp(prefix="podman-compose-helper-test.", dir=self.tmp_root))
        self.fake_bin = self.work_dir / "bin"
        self.compose_dir = self.work_dir / "compose"
        self.state_dir = self.work_dir / "state"
        self.fake_bin.mkdir()
        self.compose_dir.mkdir()
        self.state_dir.mkdir()
        self.podman_args_file = self.state_dir / "podman-args"
        self.podman_history_file = self.state_dir / "podman-history"
        self.podman_args_file.touch()
        self.podman_history_file.touch()
        self._write_fake_systemctl()
        self._write_fake_podman()

    def tearDown(self):
        shutil.rmtree(self.work_dir)

    def _write_executable(self, path: Path, body: str):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def _write_fake_systemctl(self):
        self._write_executable(
            self.fake_bin / "systemctl",
            textwrap.dedent(
                f'''#!{shutil.which("bash")}
                if [ "${{1-}}" = "--user" ] && [ "${{2-}}" = "show" ]; then
                  printf '%s\n' "${{TEST_TIMEOUT_VALUE:-5s}}"
                  exit 0
                fi
                printf 'unexpected systemctl args: %s\n' "$*" >&2
                exit 64
                '''
            ).lstrip(),
        )

    def _write_fake_podman(self):
        self._write_executable(
            self.fake_bin / "podman",
            f"#!{shutil.which('bash')}\nexec {sys.executable} {Path(__file__).with_name('fake_podman.py')} \"$@\"\n",
        )

    @property
    def runtime_dir(self):
        return self.work_dir / "runtime"

    @property
    def generated_dir(self):
        return self.compose_dir / ".podman-compose"

    @property
    def manifest_path(self):
        return self.runtime_dir / "podman-compose/test-compose.manifest"

    @property
    def state_path(self):
        return self.generated_dir / "state.json"

    def helper_env(self, **overrides):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.fake_bin}:{env['PATH']}",
                "NOTIFY_SOCKET": "/run/systemd/notify",
                "WATCHDOG_PID": "1234",
                "WATCHDOG_USEC": "1000000",
                "TEST_PODMAN_ARGS_FILE": str(self.podman_args_file),
                "TEST_PODMAN_HISTORY_FILE": str(self.podman_history_file),
            }
        )
        env.update(overrides)
        return env

    def helper_script(self, body: str) -> str:
        return textwrap.dedent(
            f"""
            set -Eeuo pipefail
            source {self.helper}
            init_vars
            PATH={self.fake_bin}:$PATH
            export PATH TEST_PODMAN_ARGS_FILE TEST_PODMAN_MODE TEST_TIMEOUT_VALUE
            runtime_dir={self.runtime_dir}
            working_dir={self.compose_dir}
            generated_dir="${{working_dir}}/.podman-compose"
            lifecycle_lock_path="${{generated_dir}}/lifecycle.lock"
            state_path="${{generated_dir}}/state.json"
            podman_compose_service_name=test-compose
            manifest_path="${{runtime_dir}}/podman-compose/${{podman_compose_service_name}}.manifest"
            compose_start_default_timeout_seconds=5
            compose_args=()
            compose_file_args=()
            {body}
            """
        )

    def run_helper(self, body: str, *, check=True, timeout=None, **env_overrides):
        return subprocess.run(
            ["bash", "-c", self.helper_script(body)],
            cwd=self.repo_root,
            env=self.helper_env(**env_overrides),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=check,
        )

    def wait_for_pid_absent(self, pid: int, timeout: float = 5.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            time.sleep(0.05)
        return False

    def assert_child_process_was_cleaned_up(self, child_pid_file: Path):
        self.assertTrue(child_pid_file.exists())
        child_pid = int(child_pid_file.read_text(encoding="utf-8").strip())
        self.assertTrue(self.wait_for_pid_absent(child_pid), f"compose child pid {child_pid} survived")

    def write_metadata(self, name: str, metadata: dict) -> Path:
        path = self.state_dir / name
        path.write_text(json.dumps(metadata), encoding="utf-8")
        return path

    def write_service_metadata(self, name: str, **overrides) -> Path:
        metadata = {
            "workingDir": str(self.compose_dir),
            "adoptionStamp": "test-adoption-stamp",
            "state": "running",
            "reconcilePolicy": "auto",
            "removalPolicy": "delete",
            "longRunning": True,
        }
        metadata.update(overrides)
        return self.write_metadata(name, metadata)

    def write_staged_service_metadata(self, name: str, **overrides):
        src_config = self.state_dir / f"{name}.config.yml"
        staged_config = self.compose_dir / "config" / f"{name}.yml"
        data_dir = self.compose_dir / "data"
        src_config.write_text("key: value\n", encoding="utf-8")
        metadata = {
            "workingDir": str(self.compose_dir),
            "adoptionStamp": "test-adoption-stamp",
            "state": "running",
            "reconcilePolicy": "auto",
            "removalPolicy": "delete",
            "longRunning": True,
            "stagedDirs": [
                {
                    "dst": str(data_dir),
                    "mode": "0755",
                    "user": None,
                    "group": None,
                    "scope": "host",
                }
            ],
            "stagedFiles": [
                {
                    "src": str(src_config),
                    "dst": str(staged_config),
                    "dstDir": str(staged_config.parent),
                    "dstDirMode": "0750",
                    "mode": "0640",
                    "user": None,
                    "group": None,
                    "scope": "host",
                }
            ],
        }
        metadata.update(overrides)
        return self.write_metadata(name, metadata), staged_config, data_dir

    def write_runtime_state(self, **overrides):
        self.generated_dir.mkdir(exist_ok=True)
        state = {
            "version": 1,
            "kind": "podman-compose-runtime-state",
            "adoptionStamp": "test-adoption-stamp",
            "reconcilePolicy": "auto",
            "restartStamp": "restart-a",
            "recreateTag": "0",
            "recreateStamp": "recreate-a",
            "recreateClassStamp": "class-a",
        }
        state.update(overrides)
        self.state_path.write_text(json.dumps(state), encoding="utf-8")

    def test_compose_up_supervised_runs_without_systemd_notify_environment(self):
        self.run_helper(
            "compose_up_supervised normal",
            TEST_PODMAN_MODE="success",
            TEST_TIMEOUT_VALUE="5s",
        )
        self.assertEqual("compose up -d --remove-orphans", self.podman_args_file.read_text().strip())

    def test_compose_up_supervised_force_recreate_adds_force_recreate(self):
        self.run_helper(
            """
            compose_args=(--project-name demo)
            compose_file_args=(-f compose.yml)
            compose_up_supervised force
            """,
            TEST_PODMAN_MODE="success",
            TEST_TIMEOUT_VALUE="5s",
        )
        self.assertEqual(
            "compose --project-name demo -f compose.yml up -d --remove-orphans --force-recreate",
            self.podman_args_file.read_text().strip(),
        )

    def test_compose_up_supervised_fails_fast_on_fatal_output(self):
        result = self.run_helper(
            "compose_up_supervised normal",
            check=False,
            timeout=5,
            TEST_PODMAN_MODE="fatal",
            TEST_TIMEOUT_VALUE="10s",
        )
        self.assertNotEqual(0, result.returncode)

    def test_compose_up_supervised_respects_systemd_timeout(self):
        result = self.run_helper(
            """
            compose_start_default_timeout_seconds=2
            compose_up_supervised normal
            """,
            check=False,
            timeout=6,
            TEST_PODMAN_MODE="timeout",
            TEST_TIMEOUT_VALUE="2s",
        )
        self.assertNotEqual(0, result.returncode)

    def test_compose_up_checked_kills_timeout_process_group_before_cleanup(self):
        child_pid_file = self.state_dir / "compose-child.pid"
        result = self.run_helper(
            """
            compose_start_default_timeout_seconds=2
            compose_up_checked normal
            """,
            check=False,
            timeout=15,
            TEST_PODMAN_MODE="timeout_child",
            TEST_TIMEOUT_VALUE="2s",
            TEST_PODMAN_CHILD_PID_FILE=str(child_pid_file),
        )

        self.assertNotEqual(0, result.returncode)
        self.assert_child_process_was_cleaned_up(child_pid_file)
        self.assertIn("podman compose process group", result.stderr)
        self.assertIn("still has live members", result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            [
                "compose up -d --remove-orphans",
                "compose down",
                "ps -a --filter label=com.docker.compose.project.working_dir="
                + str(self.compose_dir)
                + " --format {{.ID}}",
            ],
            history,
        )

    def test_compose_up_checked_kills_fatal_output_process_group_before_cleanup(self):
        child_pid_file = self.state_dir / "compose-fatal-child.pid"
        result = self.run_helper(
            """
            compose_up_checked normal
            """,
            check=False,
            timeout=15,
            TEST_PODMAN_MODE="fatal_child",
            TEST_TIMEOUT_VALUE="10s",
            TEST_PODMAN_CHILD_PID_FILE=str(child_pid_file),
        )

        self.assertNotEqual(0, result.returncode)
        self.assert_child_process_was_cleaned_up(child_pid_file)
        self.assertIn("podman compose start hit fatal output", result.stderr)
        self.assertIn("podman compose process group", result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            [
                "compose up -d --remove-orphans",
                "compose down",
                "ps -a --filter label=com.docker.compose.project.working_dir="
                + str(self.compose_dir)
                + " --format {{.ID}}",
            ],
            history,
        )

    def test_compose_down_kills_timeout_process_group(self):
        child_pid_file = self.state_dir / "compose-down-child.pid"
        result = self.run_helper(
            """
            compose_down
            """,
            check=False,
            timeout=15,
            TEST_PODMAN_MODE="down_timeout_child",
            TEST_TIMEOUT_VALUE="2s",
            TEST_PODMAN_CHILD_PID_FILE=str(child_pid_file),
        )

        self.assertNotEqual(0, result.returncode)
        self.assert_child_process_was_cleaned_up(child_pid_file)
        self.assertIn("podman compose down exceeded helper deadline", result.stderr)
        self.assertIn("podman compose process group", result.stderr)
        self.assertEqual(["compose down"], self.podman_history_file.read_text(encoding="utf-8").splitlines())

    def test_load_metadata_populates_core_fields_and_arrays(self):
        compose_file = self.compose_dir / "compose.yml"
        pull_file = self.compose_dir / "compose.pull.yml"
        metadata = self.write_metadata(
            "metadata-load.json",
            {
                "workingDir": str(self.compose_dir),
                "state": "present",
                "reconcilePolicy": "recreate",
                "removalPolicy": "stop",
                "adoptionStamp": "adopt-1",
                "recreateTag": "7",
                "recreateStamp": "stamp-1",
                "longRunning": False,
                "composeArgs": ["--project-name", "demo"],
                "composeFiles": [str(compose_file)],
                "pullComposeFiles": [str(pull_file)],
                "expectedComposeServices": ["web", "worker"],
                "reload": {
                    "method": "signal",
                    "signal": "USR1",
                    "services": ["web"],
                },
            },
        )

        result = self.run_helper(
            """
            array_json() {
              printf '%s\n' "$@" | jq -R . | jq -s .
            }
            load_metadata
            jq -cn \
              --arg workingDir "$working_dir" \
              --arg generatedDir "$generated_dir" \
              --arg manifestPath "$manifest_path" \
              --arg desiredState "$desired_state" \
              --arg reconcilePolicy "$reconcile_policy" \
              --arg removalPolicy "$removal_policy" \
              --arg adoptionStamp "$adoption_stamp" \
              --arg recreateTag "$recreate_tag" \
              --arg recreateStamp "$recreate_stamp" \
              --arg longRunning "$long_running" \
              --arg reloadMethod "$reload_method" \
              --arg reloadSignal "$reload_signal" \
              --argjson composeArgs "$(array_json "${compose_args[@]}")" \
              --argjson composeFileArgs "$(array_json "${compose_file_args[@]}")" \
              --argjson pullComposeFileArgs "$(array_json "${pull_compose_file_args[@]}")" \
              --argjson expectedComposeServices "$(array_json "${expected_compose_services[@]}")" \
              --argjson reloadServices "$(array_json "${reload_services[@]}")" \
              '{
                workingDir: $workingDir,
                generatedDir: $generatedDir,
                manifestPath: $manifestPath,
                desiredState: $desiredState,
                reconcilePolicy: $reconcilePolicy,
                removalPolicy: $removalPolicy,
                adoptionStamp: $adoptionStamp,
                recreateTag: $recreateTag,
                recreateStamp: $recreateStamp,
                longRunning: $longRunning,
                reloadMethod: $reloadMethod,
                reloadSignal: $reloadSignal,
                composeArgs: $composeArgs,
                composeFileArgs: $composeFileArgs,
                pullComposeFileArgs: $pullComposeFileArgs,
                expectedComposeServices: $expectedComposeServices,
                reloadServices: $reloadServices
              }'
            """,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
        )
        loaded = json.loads(result.stdout)
        self.assertEqual(str(self.compose_dir), loaded["workingDir"])
        self.assertEqual(str(self.generated_dir), loaded["generatedDir"])
        self.assertEqual(str(self.manifest_path), loaded["manifestPath"])
        self.assertEqual("present", loaded["desiredState"])
        self.assertEqual("recreate", loaded["reconcilePolicy"])
        self.assertEqual("stop", loaded["removalPolicy"])
        self.assertEqual("adopt-1", loaded["adoptionStamp"])
        self.assertEqual("7", loaded["recreateTag"])
        self.assertEqual("stamp-1", loaded["recreateStamp"])
        self.assertEqual("false", loaded["longRunning"])
        self.assertEqual("signal", loaded["reloadMethod"])
        self.assertEqual("USR1", loaded["reloadSignal"])
        self.assertEqual(["--project-name", "demo"], loaded["composeArgs"])
        self.assertEqual(["-f", str(compose_file)], loaded["composeFileArgs"])
        self.assertEqual(["-f", str(pull_file)], loaded["pullComposeFileArgs"])
        self.assertEqual(["web", "worker"], loaded["expectedComposeServices"])
        self.assertEqual(["web"], loaded["reloadServices"])

    def test_timeout_parsing_and_cleanup_reserve_seconds(self):
        result = self.run_helper(
            """
            parse_systemd_timespan_seconds 1500ms
            parse_systemd_timespan_seconds '2min 3s'
            parse_systemd_timespan_seconds 500us
            parse_systemd_timespan_seconds infinity
            compose_cleanup_reserve_seconds 20
            compose_cleanup_reserve_seconds 120
            compose_cleanup_reserve_seconds 600
            compose_cleanup_reserve_seconds 5
            """
        )
        self.assertEqual(["2", "123", "1", "0", "5", "12", "30", "1"], result.stdout.splitlines())

    def test_pre_start_hooks_run_in_working_dir_and_can_ignore_failure(self):
        hook_cwd = self.compose_dir / "hook.cwd"
        hook_output = self.compose_dir / "hook.out"
        metadata = self.write_metadata(
            "metadata-hooks.json",
            {
                "preStart": [
                    "pwd > hook.cwd",
                    "printf ok > hook.out",
                    "-exit 7",
                ],
            },
        )

        self.run_helper(
            f"""
            podman_compose_metadata={metadata}
            run_pre_start_hooks
            """
        )

        self.assertEqual(str(self.compose_dir), hook_cwd.read_text(encoding="utf-8").strip())
        self.assertEqual("ok", hook_output.read_text(encoding="utf-8"))

    def test_stage_runtime_files_writes_files_env_secrets_and_manifest(self):
        src_config = self.state_dir / "config.yml"
        src_secret = self.state_dir / "token"
        staged_config = self.compose_dir / "config/config.yml"
        staged_secret = self.compose_dir / "secrets/app.env"
        data_dir = self.compose_dir / "data"
        src_config.write_text("key: value\n", encoding="utf-8")
        src_secret.write_text("secret-token\n", encoding="utf-8")
        metadata = self.write_metadata(
            "metadata-staging.json",
            {
                "stagedDirs": [
                    {
                        "dst": str(data_dir),
                        "mode": "0755",
                        "user": None,
                        "group": None,
                        "scope": "host",
                    }
                ],
                "stagedFiles": [
                    {
                        "src": str(src_config),
                        "dst": str(staged_config),
                        "dstDir": str(staged_config.parent),
                        "dstDirMode": "0750",
                        "mode": "0640",
                        "user": None,
                        "group": None,
                        "scope": "host",
                    }
                ],
                "envSecretFiles": [
                    {
                        "dst": str(staged_secret),
                        "dstDir": str(staged_secret.parent),
                        "mode": "0400",
                        "user": None,
                        "group": None,
                        "scope": "host",
                        "entries": [
                            {
                                "name": "APP_TOKEN",
                                "src": str(src_secret),
                            }
                        ],
                    }
                ],
            },
        )

        self.run_helper(
            f"""
            podman_compose_metadata={metadata}
            ensure_runtime_dirs
            stage_runtime_files
            """
        )

        self.assertEqual("key: value\n", staged_config.read_text(encoding="utf-8"))
        self.assertEqual("APP_TOKEN=secret-token\n", staged_secret.read_text(encoding="utf-8"))
        self.assertTrue(data_dir.is_dir())
        self.assertEqual(0o640, stat.S_IMODE(staged_config.stat().st_mode))
        self.assertEqual(0o400, stat.S_IMODE(staged_secret.stat().st_mode))
        self.assertEqual(0o755, stat.S_IMODE(data_dir.stat().st_mode))
        self.assertEqual(
            [str(staged_config), str(staged_secret)],
            self.manifest_path.read_text(encoding="utf-8").splitlines(),
        )

    def test_assert_adoption_allowed_refuses_unmanaged_existing_working_dir(self):
        metadata = self.write_metadata("metadata-adoption-refuse.json", {})

        result = self.run_helper(
            f"""
            podman_compose_metadata={metadata}
            adoption_stamp=test-adoption-stamp
            assert_adoption_allowed
            """,
            check=False,
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("without compatible helper state", result.stderr)

    def test_assert_adoption_allowed_recovers_empty_helper_shell(self):
        metadata = self.write_metadata("metadata-adoption-recover.json", {})
        self.generated_dir.mkdir()
        (self.generated_dir / "lifecycle.lock").touch()

        result = self.run_helper(
            f"""
            podman_compose_metadata={metadata}
            adoption_stamp=test-adoption-stamp
            assert_adoption_allowed
            """
        )

        self.assertIn("Recovering uninitialized Podman compose helper working directory", result.stdout)

    def test_assert_adoption_allowed_refuses_unexpected_file_in_helper_shell(self):
        metadata = self.write_metadata("metadata-adoption-extra-file.json", {})
        self.generated_dir.mkdir()
        (self.generated_dir / "lifecycle.lock").touch()
        (self.compose_dir / "unexpected.txt").write_text("not helper-owned\n", encoding="utf-8")

        result = self.run_helper(
            f"""
            podman_compose_metadata={metadata}
            adoption_stamp=test-adoption-stamp
            assert_adoption_allowed
            """,
            check=False,
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("without compatible helper state", result.stderr)

    def test_runtime_state_records_and_clears_staging_phase(self):
        self.run_helper(
            """
            adoption_stamp=test-adoption-stamp
            reconcile_policy=restart
            restart_stamp=restart-a
            record_staging_runtime_state
            record_runtime_state
            cat "$state_path"
            """
        )

        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(1, state["version"])
        self.assertEqual("podman-compose-runtime-state", state["kind"])
        self.assertEqual("test-adoption-stamp", state["adoptionStamp"])
        self.assertEqual("restart", state["reconcilePolicy"])
        self.assertEqual("restart-a", state["restartStamp"])
        self.assertNotIn("startupPhase", state)

    def test_legacy_runtime_state_migrates_to_current_state_path(self):
        self.generated_dir.mkdir()
        legacy_state = self.generated_dir / "helper-state.json"
        legacy_state.write_text(
            json.dumps({"recreateTag": "3", "recreateStamp": "stamp-old"}),
            encoding="utf-8",
        )

        self.run_helper(
            """
            adoption_stamp=test-adoption-stamp
            migrate_legacy_runtime_state_if_needed
            """
        )

        self.assertFalse(legacy_state.exists())
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual("3", state["recreateTag"])
        self.assertEqual("stamp-old", state["recreateStamp"])
        self.assertEqual("test-adoption-stamp", state["adoptionStamp"])

    def test_should_force_recreate_respects_auto_restart_recreate_policy_classes(self):
        cases = [
            (
                "auto tag drift",
                "auto",
                {"recreateTag": "old-tag", "recreateStamp": "recreate-a", "recreateClassStamp": "class-a"},
                {"recreate_tag": "new-tag", "recreate_stamp": "recreate-a", "recreate_class_stamp": "class-a"},
                True,
            ),
            (
                "auto restart-only drift",
                "auto",
                {"recreateTag": "0", "recreateStamp": "recreate-a", "recreateClassStamp": "class-a"},
                {"recreate_tag": "0", "recreate_stamp": "recreate-b", "recreate_class_stamp": "class-a"},
                False,
            ),
            (
                "auto recreate-class drift",
                "auto",
                {"recreateTag": "0", "recreateStamp": "recreate-a", "recreateClassStamp": "class-a"},
                {"recreate_tag": "0", "recreate_stamp": "recreate-b", "recreate_class_stamp": "class-b"},
                True,
            ),
            (
                "restart policy blocks force recreate",
                "restart",
                {"recreateTag": "0", "recreateStamp": "recreate-a", "recreateClassStamp": "class-a"},
                {"recreate_tag": "0", "recreate_stamp": "recreate-b", "recreate_class_stamp": "class-b"},
                False,
            ),
            (
                "recreate policy promotes restart-class drift",
                "recreate",
                {"recreateTag": "0", "recreateStamp": "any-a", "recreateClassStamp": "class-a"},
                {"recreate_tag": "0", "recreate_stamp": "any-b", "recreate_class_stamp": "class-a"},
                True,
            ),
        ]

        for name, policy, applied_state, desired, expected in cases:
            with self.subTest(name=name):
                self.write_runtime_state(reconcilePolicy=policy, **applied_state)
                result = self.run_helper(
                    f"""
                    adoption_stamp=test-adoption-stamp
                    reconcile_policy={policy}
                    recreate_tag={desired["recreate_tag"]}
                    recreate_stamp={desired["recreate_stamp"]}
                    recreate_class_stamp={desired["recreate_class_stamp"]}
                    should_force_recreate && printf '%s\n' force || printf '%s\n' no-force
                    """
                )
                self.assertEqual("force" if expected else "no-force", result.stdout.strip())

    def test_should_force_recreate_on_restart_to_auto_or_recreate_policy_transition(self):
        for policy in ("auto", "recreate"):
            with self.subTest(policy=policy):
                self.write_runtime_state(
                    reconcilePolicy="restart",
                    recreateTag="0",
                    recreateStamp="recreate-a",
                    recreateClassStamp="class-a",
                )
                result = self.run_helper(
                    f"""
                    adoption_stamp=test-adoption-stamp
                    reconcile_policy={policy}
                    recreate_tag=0
                    recreate_stamp=recreate-a
                    recreate_class_stamp=class-a
                    should_force_recreate && printf '%s\n' force || printf '%s\n' no-force
                    """
                )
                self.assertEqual("force", result.stdout.strip())

    def test_verify_compose_state_accepts_completed_short_lived_containers(self):
        self.run_helper(
            """
            long_running=false
            verify_compose_state
            """,
            TEST_PODMAN_COMPOSE_PS_JSON='[{"State":"exited","ExitCode":0,"Labels":{"io.podman.compose.service":"job"}}]',
        )

    def test_verify_compose_state_rejects_missing_running_long_lived_containers(self):
        result = self.run_helper(
            """
            long_running=true
            verify_compose_state
            """,
            check=False,
            TEST_PODMAN_COMPOSE_PS_JSON='[{"State":"exited","ExitCode":0,"Labels":{"io.podman.compose.service":"web"}}]',
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("podman compose found no running containers", result.stderr)

    def test_verify_expected_compose_services_reports_missing_services(self):
        result = self.run_helper(
            """
            long_running=true
            expected_compose_services=(web worker)
            verify_expected_compose_services
            """,
            check=False,
            TEST_PODMAN_PS_JSON='[{"Labels":{"io.podman.compose.service":"web"}}]',
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("podman compose is missing running containers for expected services", result.stderr)
        self.assertIn("worker", result.stderr)
        self.assertNotIn("web\n", result.stderr)

    def test_reload_staging_prunes_stale_reload_files_but_keeps_other_manifest_entries(self):
        kept_file = self.compose_dir / "compose.yml"
        reload_dir = self.compose_dir / "reload"
        stale_file = reload_dir / "old.conf"
        src_reload_file = self.state_dir / "new.conf"
        staged_reload_file = reload_dir / "new.conf"
        kept_file.write_text("services: {}\n", encoding="utf-8")
        stale_file.parent.mkdir()
        stale_file.write_text("old\n", encoding="utf-8")
        src_reload_file.write_text("new\n", encoding="utf-8")
        self.manifest_path.parent.mkdir(parents=True)
        self.manifest_path.write_text(f"{kept_file}\n{stale_file}\n", encoding="utf-8")
        metadata = self.write_metadata(
            "metadata-reload-stage.json",
            {
                "reload": {
                    "dirs": [
                        {
                            "dst": str(reload_dir),
                            "mode": "0750",
                            "user": None,
                            "group": None,
                            "scope": "host",
                        }
                    ],
                    "stagedFiles": [
                        {
                            "src": str(src_reload_file),
                            "dst": str(staged_reload_file),
                            "dstDir": str(reload_dir),
                            "dstDirMode": "0750",
                            "mode": "0640",
                            "user": None,
                            "group": None,
                            "scope": "host",
                        }
                    ],
                }
            },
        )

        self.run_helper(
            f"""
            podman_compose_metadata={metadata}
            old_manifest="${{manifest_path}}.old"
            selected_manifest="${{manifest_path}}.selected"
            stage_reload_files "$old_manifest" "$selected_manifest"
            cleanup_stale_reload_files "$old_manifest" "$selected_manifest"
            write_reload_manifest "$old_manifest" "$selected_manifest" true
            """
        )

        self.assertTrue(kept_file.exists())
        self.assertFalse(stale_file.exists())
        self.assertEqual("new\n", staged_reload_file.read_text(encoding="utf-8"))
        self.assertEqual(
            [str(kept_file), str(staged_reload_file)],
            self.manifest_path.read_text(encoding="utf-8").splitlines(),
        )

    def test_cleanup_staged_dirs_under_working_dir_refuses_outside_paths(self):
        outside_dir = self.work_dir / "outside-data"
        outside_dir.mkdir()
        metadata = self.write_metadata(
            "metadata-delete-all-outside.json",
            {
                "stagedDirs": [
                    {
                        "dst": str(outside_dir),
                    }
                ]
            },
        )

        result = self.run_helper(
            f"""
            podman_compose_metadata={metadata}
            cleanup_staged_dirs_under_working_dir
            """,
            check=False,
        )

        self.assertNotEqual(0, result.returncode)
        self.assertTrue(outside_dir.exists())
        self.assertIn("refusing to remove managed staged dir outside workingDir", result.stderr)

    def test_remove_compose_project_containers_removes_live_ids_and_expected_names(self):
        self.run_helper(
            """
            expected_compose_services=(web worker)
            remove_compose_project_containers
            """,
            TEST_PODMAN_PS_IDS="abc123",
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("ps -a --filter label=com.docker.compose.project.working_dir=" + str(self.compose_dir) + " --format {{.ID}}", history)
        self.assertIn("rm -f abc123", history)
        self.assertIn("rm -f compose_web_1", history)
        self.assertIn("rm -f compose_worker_1", history)

    def test_failed_start_cleanup_preserves_retryable_state(self):
        metadata = self.write_metadata(
            "metadata-cleanup.json",
            {
                "adoptionStamp": "test-adoption-stamp",
                "stagedDirs": [],
                "stagedFiles": [],
            },
        )
        staged_compose_file = self.compose_dir / "compose.yml"
        data_dir = self.compose_dir / "data"
        data_dir.mkdir()
        self.generated_dir.mkdir()
        self.manifest_path.parent.mkdir(parents=True)
        staged_compose_file.write_text("services: {}\n", encoding="utf-8")
        self.manifest_path.write_text(str(staged_compose_file) + "\n", encoding="utf-8")

        self.run_helper(
            f"""
            podman_compose_metadata={metadata}
            adoption_stamp=test-adoption-stamp
            record_staging_runtime_state
            assert_adoption_allowed
            cleanup_runtime_files
            assert_adoption_allowed
            """,
            TEST_PODMAN_MODE="success",
            TEST_TIMEOUT_VALUE="5s",
        )

        self.assertFalse(staged_compose_file.exists())
        self.assertTrue(data_dir.exists())
        self.assertTrue(self.state_path.exists())
        self.assertEqual("staging", json.loads(self.state_path.read_text())["startupPhase"])

    def test_cmd_start_timeout_kills_process_group_and_preserves_retryable_state(self):
        metadata, staged_config, data_dir = self.write_staged_service_metadata("metadata-start-timeout.json")
        child_pid_file = self.state_dir / "cmd-start-child.pid"
        self.compose_dir.rmdir()

        result = self.run_helper(
            """
            cmd_start
            """,
            check=False,
            timeout=20,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_PODMAN_MODE="timeout_child",
            TEST_TIMEOUT_VALUE="2s",
            TEST_PODMAN_CHILD_PID_FILE=str(child_pid_file),
        )

        self.assertNotEqual(0, result.returncode)
        self.assert_child_process_was_cleaned_up(child_pid_file)
        self.assertFalse(staged_config.exists())
        self.assertTrue(data_dir.exists())
        self.assertEqual("staging", json.loads(self.state_path.read_text(encoding="utf-8"))["startupPhase"])
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("compose up -d --remove-orphans", history)
        self.assertIn("compose down", history)
        self.assertIn(
            "ps -a --filter label=com.docker.compose.project.working_dir="
            + str(self.compose_dir)
            + " --format {{.ID}}",
            history,
        )

    def test_cmd_post_stop_timeout_result_runs_failed_start_cleanup_backstop(self):
        metadata, staged_config, data_dir = self.write_staged_service_metadata("metadata-post-stop-timeout.json")
        staged_config.parent.mkdir(parents=True)
        staged_config.write_text("key: value\n", encoding="utf-8")
        data_dir.mkdir()
        self.manifest_path.parent.mkdir(parents=True)
        self.manifest_path.write_text(str(staged_config) + "\n", encoding="utf-8")
        self.write_runtime_state(startupPhase="staging")

        result = self.run_helper(
            """
            cmd_post_stop
            """,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            SERVICE_RESULT="timeout",
            TEST_PODMAN_MODE="success",
            TEST_TIMEOUT_VALUE="5s",
        )

        self.assertIn("systemd reported test-compose.service result=timeout", result.stdout)
        self.assertFalse(staged_config.exists())
        self.assertTrue(data_dir.exists())
        self.assertEqual("staging", json.loads(self.state_path.read_text(encoding="utf-8"))["startupPhase"])
        self.assertEqual(
            [
                "compose down",
                "ps -a --filter label=com.docker.compose.project.working_dir="
                + str(self.compose_dir)
                + " --format {{.ID}}",
            ],
            self.podman_history_file.read_text(encoding="utf-8").splitlines(),
        )

    def test_pre_stop_hard_failure_blocks_compose_stop_after_prior_hooks(self):
        hook_log = self.compose_dir / "pre-stop.log"
        metadata = self.write_service_metadata(
            "metadata-pre-stop-hard.json",
            preStop=[
                f"printf 'first\\n' >> {shlex.quote(str(hook_log))}",
                "exit 42",
                f"printf 'never\\n' >> {shlex.quote(str(hook_log))}",
            ],
        )

        result = self.run_helper(
            "cmd_stop",
            check=False,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_TIMEOUT_VALUE="5s",
        )

        self.assertNotEqual(0, result.returncode)
        self.assertEqual(["first"], hook_log.read_text(encoding="utf-8").splitlines())
        self.assertEqual("", self.podman_history_file.read_text(encoding="utf-8"))
        self.assertIn("preStop hook failed with status 42", result.stderr)

    def test_pre_stop_ignored_failure_continues_before_compose_stop(self):
        hook_log = self.compose_dir / "pre-stop.log"
        metadata = self.write_service_metadata(
            "metadata-pre-stop-ignored.json",
            preStop=[
                f"printf 'first\\n' >> {shlex.quote(str(hook_log))}",
                f"-printf 'ignored\\n' >> {shlex.quote(str(hook_log))}; exit 42",
                f"printf 'after\\n' >> {shlex.quote(str(hook_log))}",
            ],
        )

        self.run_helper(
            "cmd_stop",
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_TIMEOUT_VALUE="5s",
        )

        self.assertEqual(["first", "ignored", "after"], hook_log.read_text(encoding="utf-8").splitlines())
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertEqual(["compose down"], history)

    def test_cmd_start_adoption_forces_recreate_and_records_recreate_state(self):
        metadata = self.write_service_metadata(
            "metadata-adopt-start.json",
            adopt=True,
            reconcilePolicy="restart",
            restartStamp="restart-a",
            recreateTag="0",
            recreateStamp="recreate-a",
            recreateClassStamp="class-a",
            stagedFiles=[],
        )

        self.run_helper(
            """
            notify_ready_and_monitor() {
              printf '%s\n' monitor-skipped
            }
            cmd_start
            """,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_TIMEOUT_VALUE="5s",
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("compose up -d --remove-orphans --force-recreate", history)
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual("restart", state["reconcilePolicy"])
        self.assertEqual("restart-a", state["restartStamp"])
        self.assertEqual("recreate-a", state["recreateStamp"])
        self.assertEqual("class-a", state["recreateClassStamp"])

    def test_cmd_start_force_recreates_when_running_container_pid_is_missing(self):
        metadata = self.write_service_metadata(
            "metadata-stale-pid-start.json",
            adopt=False,
            reconcilePolicy="auto",
            restartStamp="restart-a",
            recreateTag="0",
            recreateStamp="recreate-a",
            recreateClassStamp="class-a",
            stagedFiles=[],
        )
        self.write_runtime_state(
            reconcilePolicy="auto",
            restartStamp="restart-a",
            recreateTag="0",
            recreateStamp="recreate-a",
            recreateClassStamp="class-a",
        )

        result = self.run_helper(
            """
            notify_ready_and_monitor() {
              printf '%s\n' monitor-skipped
            }
            cmd_start
            """,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_TIMEOUT_VALUE="5s",
            TEST_PODMAN_PS_IDS="stale123",
            TEST_PODMAN_INSPECT_STATE_JSON='{"Running":true,"Pid":999999999,"ConmonPid":1}',
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn(
            "ps -a --filter label=com.docker.compose.project.working_dir=" + str(self.compose_dir) + " --format {{.ID}}",
            history,
        )
        self.assertIn("inspect --format {{json .State}} stale123", history)
        self.assertIn("compose up -d --remove-orphans --force-recreate", history)
        self.assertIn("marked running but runtime pid 999999999 is not present", result.stderr)
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual("recreate-a", state["recreateStamp"])
        self.assertEqual("class-a", state["recreateClassStamp"])


if __name__ == "__main__":
    unittest.main()
