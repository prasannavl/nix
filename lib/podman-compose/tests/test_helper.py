import json
import os
import pwd
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
        self.systemctl_history_file = self.state_dir / "systemctl-history"
        self.systemd_notify_history_file = self.state_dir / "systemd-notify-history"
        self.podman_args_file.touch()
        self.podman_history_file.touch()
        self.systemctl_history_file.touch()
        self.systemd_notify_history_file.touch()
        self._write_fake_systemctl()
        self._write_fake_systemd_notify()
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
                  for arg in "$@"; do
                    case "$arg" in
                      --property=ActiveState)
                        printf '%s\n' "${{TEST_SYSTEMCTL_ACTIVE_STATE:-active}}"
                        exit 0
                        ;;
                      --property=Job)
                        printf '%s\n' "${{TEST_SYSTEMCTL_JOB:-}}"
                        exit 0
                        ;;
                    esac
                  done
                  case "$*" in
                    *test-compose-start-worker.service*)
                      printf '%s\n' "${{TEST_WORKER_TIMEOUT_VALUE:-${{TEST_TIMEOUT_VALUE:-5s}}}}"
                      exit 0
                      ;;
                  esac
	                  printf '%s\n' "${{TEST_TIMEOUT_VALUE:-5s}}"
	                  exit 0
	                fi
	                if [ "${{1-}}" = "--user" ] && [ "${{2-}}" = "reset-failed" ]; then
	                  printf '%s\n' "$*" >>"${{TEST_SYSTEMCTL_HISTORY_FILE:-/dev/null}}"
	                  exit 0
	                fi
	                if [ "${{1-}}" = "--user" ] && [ "${{2-}}" = "start" ]; then
	                  printf '%s\n' "$*" >>"${{TEST_SYSTEMCTL_HISTORY_FILE:-/dev/null}}"
	                  exit "${{TEST_SYSTEMCTL_START_EXIT:-0}}"
	                fi
	                printf 'unexpected systemctl args: %s\n' "$*" >&2
	                exit 64
	                '''
            ).lstrip(),
        )

    def _write_fake_systemd_notify(self):
        self._write_executable(
            self.fake_bin / "systemd-notify",
            textwrap.dedent(
                f'''#!{shutil.which("bash")}
                printf '%s\n' "$*" >>"${{TEST_SYSTEMD_NOTIFY_HISTORY_FILE:-/dev/null}}"
                exit 0
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
                "TEST_SYSTEMCTL_HISTORY_FILE": str(self.systemctl_history_file),
                "TEST_SYSTEMD_NOTIFY_HISTORY_FILE": str(self.systemd_notify_history_file),
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

    def assert_compose_up_in_history(self, history, *, force_recreate=False):
        suffix = " up --no-build -d --remove-orphans"
        if force_recreate:
            suffix += " --force-recreate"
        self.assertTrue(
            any(line.startswith("compose ") and suffix in line for line in history),
            "\n".join(history),
        )

    def assert_compose_force_recreate_not_in_history(self, history):
        self.assertFalse(
            any(
                line.startswith("compose ")
                and " up --no-build -d --remove-orphans --force-recreate" in line
                for line in history
            ),
            "\n".join(history),
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

    def test_helper_invoked_as_script_detects_generated_wrapper(self):
        sourced = self.run_helper(
            """
            if helper_invoked_as_script; then
              printf '%s\n' top-level
            else
              printf '%s\n' sourced
            fi
            """
        )
        self.assertEqual("sourced", sourced.stdout.strip())

        wrapped = self.run_helper(
            """
            if helper_invoked_as_script; then
              printf '%s\n' top-level
            else
              printf '%s\n' sourced
            fi
            """,
            NIX_PODMAN_COMPOSE_HELPER_TOPLEVEL="1",
        )
        self.assertEqual("top-level", wrapped.stdout.strip())

    def test_notify_ready_and_monitor_execs_helper_self(self):
        monitor_wrapper = self.state_dir / "monitor-wrapper"
        self._write_executable(
            monitor_wrapper,
            textwrap.dedent(
                f'''#!{shutil.which("bash")}
                printf 'monitor:%s\n' "$*"
                '''
            ).lstrip(),
        )

        result = self.run_helper(
            """
            notify_ready_and_monitor "podman compose start dispatched"
            """,
            NIX_PODMAN_COMPOSE_HELPER_SELF=str(monitor_wrapper),
        )

        self.assertEqual(0, result.returncode)
        self.assertTrue(result.stdout.strip().endswith("monitor:monitor"))
        self.assertIn(
            "--ready --status=podman compose start dispatched",
            self.systemd_notify_history_file.read_text(encoding="utf-8"),
        )

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
            "version": 3,
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
        self.assertEqual("compose up --no-build -d --remove-orphans", self.podman_args_file.read_text().strip())

    def test_compose_up_supervised_forces_local_pull_policy_for_known_services(self):
        self.run_helper(
            """
            generated_dir="$working_dir/.podman-compose"
            expected_compose_services=(web worker)
            compose_file_args=(-f compose.yml)
            compose_up_supervised normal
            """,
            TEST_PODMAN_MODE="success",
            TEST_TIMEOUT_VALUE="5s",
        )

        override = self.generated_dir / "local-pull-policy.override.json"
        self.assertEqual(
            {
                "services": {
                    "web": {"pull_policy": "never"},
                    "worker": {"pull_policy": "never"},
                }
            },
            json.loads(override.read_text(encoding="utf-8")),
        )
        self.assertEqual(
            f"compose -f compose.yml -f {override} up --no-build -d --remove-orphans",
            self.podman_args_file.read_text().strip(),
        )

    def test_close_lifecycle_fds_for_child_closes_rootless_lock_fd(self):
        result = self.run_helper(
            """
            mkdir -p "$generated_dir"
            : > "$state_path"
            exec 6<> "$state_path"
            exec 7<> "$state_path"
            exec 8<> "$state_path"
            exec 9<> "$state_path"
            close_lifecycle_fds_for_child
            for fd in 6 7 8 9; do
              if [ -e "/proc/$$/fd/$fd" ]; then
                printf 'open:%s\n' "$fd"
              else
                printf 'closed:%s\n' "$fd"
              fi
            done
            """
        )

        self.assertEqual(
            ["closed:6", "closed:7", "closed:8", "closed:9"],
            result.stdout.splitlines(),
        )

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
            "compose --project-name demo -f compose.yml up --no-build -d --remove-orphans --force-recreate",
            self.podman_args_file.read_text().strip(),
        )

    def test_compose_up_force_recreate_removes_then_uses_normal_up(self):
        self.run_helper(
            """
            compose_project_container_ids() { printf '%s\n' stale-container; }
            remove_container_target() { printf 'removed %s\n' "$1"; }
            compose_up_force_recreate
            """,
            TEST_PODMAN_MODE="success",
            TEST_TIMEOUT_VALUE="5s",
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("compose up --no-build -d --remove-orphans", history)
        self.assertNotIn("compose up --no-build -d --remove-orphans --force-recreate", history)

    def test_compose_up_supervised_fails_fast_on_fatal_output(self):
        result = self.run_helper(
            "compose_up_supervised normal",
            check=False,
            timeout=5,
            TEST_PODMAN_MODE="fatal",
            TEST_TIMEOUT_VALUE="10s",
        )
        self.assertEqual(75, result.returncode)

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
        self.assertEqual(75, result.returncode)

    def test_start_uses_service_timeout_budget(self):
        metadata = self.write_service_metadata(
            "metadata-start-timeout.json",
        )

        result = self.run_helper(
            """
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            stage_runtime_files() { :; }
            record_staging_runtime_state() { :; }
            clear_removal_policy_marker() { :; }
            run_pre_start_hooks() { :; }
            clear_start_in_progress() { :; }
            compose_pull() { :; }
            compose_up_checked() {
              compose_start_timeout_seconds
            }
            record_runtime_state() { :; }
            notify_ready_and_monitor() { :; }
            cmd_start
            """,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_TIMEOUT_VALUE="7min",
        )

        self.assertEqual("420\n", result.stdout)

    def test_start_preserves_infinite_timeout_budget(self):
        metadata = self.write_service_metadata(
            "metadata-start-infinite-timeout.json",
        )

        result = self.run_helper(
            """
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            stage_runtime_files() { :; }
            record_staging_runtime_state() { :; }
            clear_removal_policy_marker() { :; }
            run_pre_start_hooks() { :; }
            clear_start_in_progress() { :; }
            compose_pull() { :; }
            compose_up_checked() {
              compose_start_timeout_seconds
            }
            record_runtime_state() { :; }
            notify_ready_and_monitor() { :; }
            cmd_start
            """,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_TIMEOUT_VALUE="infinity",
        )

        self.assertEqual("0\n", result.stdout)

    def test_compose_stop_timeout_caps_systemd_timeout(self):
        result = self.run_helper(
            """
            compose_stop_default_timeout_seconds=45
            compose_stop_timeout_seconds
            """,
            TEST_TIMEOUT_VALUE="3min",
        )

        self.assertEqual("45\n", result.stdout)

    def test_compose_up_does_not_hold_dns_repair_lock(self):
        result = self.run_helper(
            """
            install -d -m 0700 "$runtime_dir/podman-compose"
            (
              exec 9>"$runtime_dir/podman-compose/rootless-network-dns-v2.lock"
              flock -x 9
              sleep 20
            ) &
            holder_pid="$!"
            trap 'kill "$holder_pid" 2>/dev/null || true; wait "$holder_pid" 2>/dev/null || true' EXIT
            compose_up
            """,
            timeout=5,
            TEST_PODMAN_MODE="success",
            TEST_TIMEOUT_VALUE="5s",
        )

        self.assertIn("fake podman compose up ok", result.stdout)

    def test_compose_up_releases_rootless_lock_before_long_start(self):
        result = self.run_helper(
            """
            podman_rootless_lifecycle_lock() {
              podman_rootless_lifecycle_lock_depth=$((podman_rootless_lifecycle_lock_depth + 1))
            }
            podman_rootless_lifecycle_unlock() {
              podman_rootless_lifecycle_lock_depth=$((podman_rootless_lifecycle_lock_depth - 1))
            }
            remove_conflicting_compose_container_names() {
              printf 'preflight-depth=%s\n' "$podman_rootless_lifecycle_lock_depth"
            }
            compose_up_supervised() {
              printf 'up-depth=%s\n' "$podman_rootless_lifecycle_lock_depth"
            }
            compose_up
            """
        )

        self.assertEqual(["preflight-depth=1", "up-depth=0"], result.stdout.splitlines())

    def test_start_releases_lifecycle_locks_before_compose_up_checked(self):
        metadata = self.write_service_metadata(
            "metadata-start-rootless-critical-sections.json",
        )

        result = self.run_helper(
            """
            podman_compose_metadata=$NIX_PODMAN_COMPOSE_METADATA
            load_metadata
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            clear_removal_policy_marker() { :; }
            stage_runtime_files() { :; }
            record_staging_runtime_state() { :; }
            run_pre_start_hooks() { :; }
            clear_start_in_progress() { :; }
            lifecycle_lock_depth=0
            lock_lifecycle_exclusive() {
              lifecycle_lock_depth=$((lifecycle_lock_depth + 1))
            }
            unlock_lifecycle_exclusive() {
              lifecycle_lock_depth=$((lifecycle_lock_depth - 1))
            }
            podman_rootless_lifecycle_lock() {
              podman_rootless_lifecycle_lock_depth=$((podman_rootless_lifecycle_lock_depth + 1))
            }
            podman_rootless_lifecycle_unlock() {
              podman_rootless_lifecycle_lock_depth=$((podman_rootless_lifecycle_lock_depth - 1))
            }
            compose_start_plan() {
              printf 'plan-depth=rootless:%s lifecycle:%s\n' "$podman_rootless_lifecycle_lock_depth" "$lifecycle_lock_depth" >&2
              printf 'normal\t0\n'
            }
            compose_up_checked() {
              printf 'up-depth=rootless:%s lifecycle:%s\n' "$podman_rootless_lifecycle_lock_depth" "$lifecycle_lock_depth" >&2
            }
            record_runtime_state() { :; }
            notify_ready_and_monitor() { :; }
            cmd_start
            """,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_TIMEOUT_VALUE="5s",
        )

        self.assertEqual(
            [
                "plan-depth=rootless:1 lifecycle:1",
                "up-depth=rootless:0 lifecycle:0",
            ],
            result.stderr.splitlines(),
        )

    def test_compose_up_fatal_line_matches_image_pull_errors(self):
        result = self.run_helper(
            """
            compose_up_fatal_line 'image pull-error  ghcr.io/jitsi/web:stable manifest unknown'
            """
        )

        self.assertEqual(0, result.returncode)

    def test_compose_pull_fatal_line_matches_false_success_copy_errors(self):
        result = self.run_helper(
            """
            compose_pull_fatal_line 'Error: unable to copy from source docker://nats:2.14.0-alpine: toomanyrequests'
            """
        )

        self.assertEqual(0, result.returncode)

    def test_compose_pull_fails_on_fatal_output_even_when_podman_exits_zero(self):
        pull_file = self.state_dir / "compose.pull.yml"
        pull_file.write_text("services: {}\n", encoding="utf-8")

        result = self.run_helper(
            f"""
            pull_compose_file_args=(-f {shlex.quote(str(pull_file))})
            ensure_runtime_dirs
            compose_pull
            """,
            check=False,
            TEST_PODMAN_MODE="pull_fatal_zero",
        )

        self.assertEqual(1, result.returncode)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertEqual([f"compose -f {pull_file} pull"], history)
        self.assertIn("treating pull as failed", result.stderr)

    def test_cmd_image_pull_retries_fatal_output_ten_times(self):
        pull_file = self.state_dir / "compose.pull.yml"
        self.compose_dir.rmdir()
        pull_file.write_text("services: {}\n", encoding="utf-8")
        metadata = self.write_service_metadata(
            "metadata-image-pull-retry.json",
            pullComposeFiles=[str(pull_file)],
        )

        result = self.run_helper(
            """
            cmd_image_pull
            """,
            check=False,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            NIX_PODMAN_COMPOSE_IMAGE_PULL_RETRY_DELAY_SECONDS="0",
            TEST_PODMAN_MODE="pull_fatal_zero",
        )

        self.assertEqual(1, result.returncode)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertEqual([f"compose -f {pull_file} pull"] * 10, history)
        self.assertIn("retrying attempt 10/10", result.stderr)
        self.assertIn("failed for test-compose after 10 attempt(s)", result.stderr)

    def test_cmd_image_pull_stops_retry_after_success(self):
        pull_file = self.state_dir / "compose.pull.yml"
        self.compose_dir.rmdir()
        pull_file.write_text("services: {}\n", encoding="utf-8")
        metadata = self.write_service_metadata(
            "metadata-image-pull-eventual-success.json",
            pullComposeFiles=[str(pull_file)],
        )

        result = self.run_helper(
            """
            cmd_image_pull
            """,
            check=False,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            NIX_PODMAN_COMPOSE_IMAGE_PULL_RETRY_DELAY_SECONDS="0",
            TEST_PODMAN_MODE="pull_fatal_then_success",
            TEST_PODMAN_PULL_SUCCEED_AFTER="3",
        )

        self.assertEqual(0, result.returncode, result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertEqual([f"compose -f {pull_file} pull"] * 3, history)
        self.assertIn("retrying attempt 2/10", result.stderr)
        self.assertIn("retrying attempt 3/10", result.stderr)

    def test_cmd_image_pull_skips_when_image_pull_stamp_current(self):
        pull_file = self.state_dir / "compose.pull.yml"
        status_file = self.state_dir / "image-pull-status"
        pull_file.write_text("services: {}\n", encoding="utf-8")
        self.write_runtime_state(imagePullStamp="pull-a")
        metadata = self.write_service_metadata(
            "metadata-image-pull-current.json",
            pullComposeFiles=[str(pull_file)],
            declaredImages=["docker.io/library/nginx:latest"],
            imagePullStamp="pull-a",
        )

        result = self.run_helper(
            """
            cmd_image_pull
            """,
            check=False,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            NIX_PODMAN_COMPOSE_IMAGE_PULL_STATUS_FILE=str(status_file),
            TEST_PODMAN_EXISTING_IMAGES="docker.io/library/nginx:latest",
            TEST_PODMAN_MODE="pull_fatal_zero",
        )

        self.assertEqual(0, result.returncode, result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertEqual(["image exists docker.io/library/nginx:latest"], history)
        self.assertEqual("", result.stdout)
        self.assertEqual("skipped\n", status_file.read_text(encoding="utf-8"))

    def test_cmd_image_pull_does_not_skip_when_stamp_current_but_image_missing(self):
        pull_file = self.state_dir / "compose.pull.yml"
        pull_file.write_text("services: {}\n", encoding="utf-8")
        self.write_runtime_state(imagePullStamp="pull-a")
        metadata = self.write_service_metadata(
            "metadata-image-pull-current-image-missing.json",
            pullComposeFiles=[str(pull_file)],
            declaredImages=["docker.io/library/nginx:latest"],
            imagePullStamp="pull-a",
        )

        result = self.run_helper(
            """
            cmd_image_pull
            """,
            check=False,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            NIX_PODMAN_COMPOSE_IMAGE_PULL_RETRY_DELAY_SECONDS="0",
            NIX_PODMAN_COMPOSE_IMAGE_PULL_RETRY_ATTEMPTS="1",
            TEST_PODMAN_MODE="success",
        )

        self.assertEqual(0, result.returncode, result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            [
                "image exists docker.io/library/nginx:latest",
                f"compose -f {pull_file} pull",
            ],
            history,
        )

    def test_cmd_image_pull_records_image_pull_stamp_after_success(self):
        pull_file = self.state_dir / "compose.pull.yml"
        status_file = self.state_dir / "image-pull-status"
        pull_file.write_text("services: {}\n", encoding="utf-8")
        self.write_runtime_state(imagePullStamp="pull-old")
        metadata = self.write_service_metadata(
            "metadata-image-pull-record.json",
            pullComposeFiles=[str(pull_file)],
            declaredImages=["docker.io/library/nginx:latest"],
            imagePullStamp="pull-new",
        )

        result = self.run_helper(
            """
            cmd_image_pull
            """,
            check=False,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            NIX_PODMAN_COMPOSE_IMAGE_PULL_STATUS_FILE=str(status_file),
            TEST_PODMAN_MODE="success",
        )

        self.assertEqual(0, result.returncode, result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertEqual([f"compose -f {pull_file} pull"], history)
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual("pull-new", state["imagePullStamp"])
        self.assertEqual("pulled\n", status_file.read_text(encoding="utf-8"))

    def test_image_pull_all_is_quiet_when_all_entries_skip(self):
        self.runtime_dir.mkdir()
        owner = pwd.getpwuid(os.getuid()).pw_name
        plan = self.state_dir / "image-pulls.json"
        plan.write_text(
            json.dumps(
                [
                    {
                        "user": owner,
                        "uid": os.getuid(),
                        "serviceName": "test-compose",
                        "metadataFile": str(self.state_dir / "metadata.json"),
                        "helper": str(shutil.which("true")),
                        "imageTag": "0",
                    }
                ]
            ),
            encoding="utf-8",
        )

        result = subprocess.run(
            [
                shutil.which("bash"),
                "-c",
                textwrap.dedent(
                    f"""
                    plan={shlex.quote(str(plan))}
                    source lib/podman-compose/image-pull-all.sh
                    runtime_dir_for_uid() {{
                      printf '%s\n' {shlex.quote(str(self.runtime_dir))}
                    }}
                    home_for_user() {{
                      printf '%s\n' {shlex.quote(str(self.work_dir))}
                    }}
                    run_as_owner() {{
                      printf '%s\n' skipped >"$status_file"
                    }}
                    main
                    """
                ),
            ],
            cwd=self.repo_root,
            env=self.helper_env(),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("", result.stdout)

    def test_compose_up_fatal_line_matches_exhausted_podman_locks(self):
        result = self.run_helper(
            """
            compose_up_fatal_line 'Error: allocating lock for new container: allocation failed; exceeded num_locks (4096)'
            """
        )

        self.assertEqual(0, result.returncode)

    def test_compose_up_checked_kills_timeout_process_group_before_cleanup(self):
        child_pid_file = self.state_dir / "compose-child.pid"
        result = self.run_helper(
            """
            compose_start_default_timeout_seconds=2
            restart_aardvark_dns() { :; }
            compose_up_checked normal
            """,
            check=False,
            timeout=15,
            TEST_PODMAN_MODE="timeout_child",
            TEST_TIMEOUT_VALUE="2s",
            TEST_PODMAN_CHILD_PID_FILE=str(child_pid_file),
        )

        self.assertEqual(75, result.returncode)
        self.assert_child_process_was_cleaned_up(child_pid_file)
        self.assertIn("podman compose process group", result.stderr)
        self.assertIn("still has live members", result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        # Stuck starts exit with 75 before the DNS-repair retry path.
        first_up = history.index("compose up --no-build -d --remove-orphans")
        self.assertGreaterEqual(first_up, 0)

    def test_compose_up_checked_retries_when_up_leaves_created_containers(self):
        result = self.run_helper(
            """
            compose_start_default_timeout_seconds=20
            compose_start_state_stall_seconds=1
            restart_aardvark_dns() { :; }
            compose_up_checked normal
            """,
            check=False,
            timeout=10,
            TEST_PODMAN_MODE="timeout",
            TEST_TIMEOUT_VALUE="20s",
            TEST_PODMAN_COMPOSE_PS_JSON_AFTER_UP=json.dumps(
                [
                    {
                        "State": "created",
                        "Labels": {"io.podman.compose.service": "db"},
                        "Names": ["compose_db_1"],
                    }
                ]
            ),
            TEST_PODMAN_PS_IDS="compose_db_1",
        )

        self.assertEqual(75, result.returncode)
        self.assertIn("podman compose start made no healthy state progress", result.stderr)
        self.assertIn("compose_db_1: state=created", result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assert_compose_up_in_history(history)
        self.assertIn("compose ps --format json", history)

    def test_compose_up_checked_retries_when_up_never_creates_expected_containers(self):
        result = self.run_helper(
            """
            compose_start_default_timeout_seconds=20
            compose_start_state_stall_seconds=1
            expected_compose_services=(web worker)
            restart_aardvark_dns() { :; }
            compose_up_checked normal
            """,
            check=False,
            timeout=10,
            TEST_PODMAN_MODE="timeout",
            TEST_TIMEOUT_VALUE="20s",
            TEST_PODMAN_COMPOSE_PS_JSON_AFTER_UP="[]",
        )

        self.assertEqual(75, result.returncode)
        self.assertIn("podman compose start made no healthy state progress", result.stderr)
        self.assertIn("podman compose has no managed containers for expected services during start", result.stderr)
        self.assertIn("web", result.stderr)
        self.assertIn("worker", result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assert_compose_up_in_history(history)
        self.assertIn("compose ps --format json", history)

    def test_compose_up_checked_retries_when_up_misses_expected_container(self):
        result = self.run_helper(
            """
            compose_start_default_timeout_seconds=20
            compose_start_state_stall_seconds=1
            expected_compose_services=(web worker)
            restart_aardvark_dns() { :; }
            compose_up_checked normal
            """,
            check=False,
            timeout=10,
            TEST_PODMAN_MODE="timeout",
            TEST_TIMEOUT_VALUE="20s",
            TEST_PODMAN_COMPOSE_PS_JSON_AFTER_UP=json.dumps(
                [
                    {
                        "State": "running",
                        "Labels": {"io.podman.compose.service": "web"},
                        "Names": ["compose_web_1"],
                    }
                ]
            ),
            TEST_PODMAN_PS_IDS="compose_web_1",
        )

        self.assertEqual(75, result.returncode)
        self.assertIn("podman compose start made no healthy state progress", result.stderr)
        self.assertIn("podman compose is missing running containers for expected services during start", result.stderr)
        self.assertNotIn("web\n", result.stderr)
        self.assertIn("worker", result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assert_compose_up_in_history(history)
        self.assertIn("compose ps --format json", history)

    def test_compose_up_checked_kills_fatal_output_process_group_before_cleanup(self):
        child_pid_file = self.state_dir / "compose-fatal-child.pid"
        result = self.run_helper(
            """
            restart_aardvark_dns() { :; }
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
        first_up = history.index("compose up --no-build -d --remove-orphans")
        self.assertGreaterEqual(first_up, 0)

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
        self.assertEqual(
            [
                "ps -a --filter label=com.docker.compose.project.working_dir="
                + str(self.compose_dir)
                + " --format {{.ID}}",
                "compose down",
            ],
            self.podman_history_file.read_text(encoding="utf-8").splitlines(),
        )

    def test_restart_aardvark_dns_removes_stale_config_files(self):
        aardvark_dir = self.runtime_dir / "containers/networks/aardvark-dns"
        aardvark_dir.mkdir(parents=True)
        stale_config = aardvark_dir / "stale_default"
        live_config = aardvark_dir / "live_default"
        stale_config.write_text(
            "10.89.2.1\n"
            "stale-container 10.89.2.2 stale_service,stale\n",
            encoding="utf-8",
        )
        live_config.write_text(
            "10.89.3.1\n"
            "live-container 10.89.3.2 live_service,live\n",
            encoding="utf-8",
        )

        result = self.run_helper(
            "restart_aardvark_dns test-reason",
            TEST_PODMAN_PS_IDS="live-container",
        )

        self.assertEqual(0, result.returncode)
        self.assertFalse(stale_config.exists())
        self.assertTrue(live_config.exists())
        self.assertIn("removing stale podman aardvark DNS config", result.stdout)

    def test_start_compose_up_does_not_trigger_dns_cleanup_when_healthy(self):
        metadata = self.write_service_metadata("dns-repair-start.json")
        self.write_runtime_state()

        result = self.run_helper(
            """
            notify_ready_and_monitor() { return 0; }
            cmd_start
            """,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_PODMAN_MODE="success",
        )

        self.assertEqual(0, result.returncode)
        self.assertNotIn("removing stale podman aardvark DNS config", result.stdout)
        self.assertIn(
            "compose up --no-build -d --remove-orphans",
            self.podman_history_file.read_text(encoding="utf-8").splitlines(),
        )

    def test_cmd_start_pre_pulls_images_before_compose_up(self):
        compose_file = self.state_dir / "compose.yml"
        pull_file = self.state_dir / "compose.pull.yml"
        self.compose_dir.rmdir()
        compose_file.write_text("services: {}\n", encoding="utf-8")
        pull_file.write_text("services: {}\n", encoding="utf-8")
        metadata = self.write_service_metadata(
            "metadata-start-pull.json",
            composeFiles=[str(compose_file)],
            pullComposeFiles=[str(pull_file)],
        )

        result = self.run_helper(
            """
            notify_ready_and_monitor() { return 0; }
            cmd_start
            """,
            check=False,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_PODMAN_MODE="success",
        )

        self.assertEqual(0, result.returncode, result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        pull_idx = history.index(f"compose -f {pull_file} pull")
        up_idx = history.index(f"compose -f {compose_file} up --no-build -d --remove-orphans")
        self.assertLess(pull_idx, up_idx, "compose pull must run before compose up")

    def test_cmd_start_skips_pull_when_runtime_state_matches(self):
        compose_file = self.state_dir / "compose.yml"
        pull_file = self.state_dir / "compose.pull.yml"
        compose_file.write_text("services: {}\n", encoding="utf-8")
        pull_file.write_text("services: {}\n", encoding="utf-8")
        self.write_runtime_state(restartStamp="restart-a")
        metadata = self.write_service_metadata(
            "metadata-start-no-pull.json",
            composeFiles=[str(compose_file)],
            pullComposeFiles=[str(pull_file)],
            restartStamp="restart-a",
        )

        result = self.run_helper(
            """
            notify_ready_and_monitor() { return 0; }
            cmd_start
            """,
            check=False,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_PODMAN_MODE="success",
        )

        self.assertEqual(0, result.returncode, result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn(f"compose -f {pull_file} pull", history)
        self.assertIn(f"compose -f {compose_file} up --no-build -d --remove-orphans", history)

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
                "declaredImages": ["docker.io/library/nginx:latest"],
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
              --argjson declaredImages "$(array_json "${declared_images[@]}")" \
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
                declaredImages: $declaredImages,
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
        self.assertEqual(["docker.io/library/nginx:latest"], loaded["declaredImages"])
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

    def test_infinite_systemd_timeout_stays_unbounded(self):
        result = self.run_helper(
            """
            compose_unit_timeout_seconds test-compose-start-worker.service TimeoutStartUSec 900
            """,
            TEST_WORKER_TIMEOUT_VALUE="infinity",
        )

        self.assertEqual("0\n", result.stdout)

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

    def test_post_start_hooks_run_after_verified_start(self):
        hook_log = self.compose_dir / "post-start.log"
        metadata = self.write_service_metadata(
            "metadata-post-start-hooks.json",
            postStart=[f"printf 'post\\n' >> {shlex.quote(str(hook_log))}"],
        )

        self.run_helper(
            """
            podman_compose_metadata=$NIX_PODMAN_COMPOSE_METADATA
            load_metadata
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            clear_removal_policy_marker() { :; }
            stage_runtime_files() { :; }
            record_staging_runtime_state() { :; }
            run_pre_start_hooks() { :; }
            clear_start_in_progress() { :; }
            compose_pull() { :; }
            compose_up_checked() { printf 'compose-started\n'; }
            record_runtime_state() { printf 'state-recorded\n'; }
            notify_ready_and_monitor() { :; }
            cmd_start
            """,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_TIMEOUT_VALUE="5s",
        )

        self.assertEqual(["post"], hook_log.read_text(encoding="utf-8").splitlines())

    def test_post_start_hooks_run_outside_lifecycle_locks(self):
        hook_log = self.compose_dir / "post-start-rootless.log"
        metadata = self.write_service_metadata(
            "metadata-post-start-rootless-lock.json",
            postStart=[f"printf 'post\\n' >> {shlex.quote(str(hook_log))}"],
        )

        self.run_helper(
            """
            podman_compose_metadata=$NIX_PODMAN_COMPOSE_METADATA
            load_metadata
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            clear_removal_policy_marker() { :; }
            stage_runtime_files() { :; }
            record_staging_runtime_state() { :; }
            run_pre_start_hooks() { :; }
            clear_start_in_progress() { :; }
            compose_up_checked() { printf 'compose-started\n'; }
            compose_pull() { printf 'compose-pulled\n' >> "$working_dir/post-start-rootless-trace.log"; }
            record_runtime_state() { printf 'state-recorded\n'; }
            lock_lifecycle_exclusive() {
              printf 'lifecycle-locked\n' >> "$working_dir/post-start-rootless-trace.log"
            }
            unlock_lifecycle_exclusive() {
              printf 'lifecycle-unlocked\n' >> "$working_dir/post-start-rootless-trace.log"
            }
            podman_rootless_lifecycle_lock() {
              if [ "$podman_rootless_lifecycle_lock_depth" -gt 0 ]; then
                podman_rootless_lifecycle_lock_depth=$((podman_rootless_lifecycle_lock_depth + 1))
                return 0
              fi
              printf 'rootless-locked\n' >> "$working_dir/post-start-rootless-trace.log"
              podman_rootless_lifecycle_lock_depth=1
            }
            podman_rootless_lifecycle_unlock() {
              if [ "$podman_rootless_lifecycle_lock_depth" -le 0 ]; then
                return 0
              fi
              podman_rootless_lifecycle_lock_depth=$((podman_rootless_lifecycle_lock_depth - 1))
              if [ "$podman_rootless_lifecycle_lock_depth" -gt 0 ]; then
                return 0
              fi
              printf 'rootless-unlocked\n' >> "$working_dir/post-start-rootless-trace.log"
            }
            notify_ready_and_monitor() { :; }
            cmd_start
            """,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_TIMEOUT_VALUE="5s",
        )

        self.assertEqual(["post"], hook_log.read_text(encoding="utf-8").splitlines())
        trace = (self.compose_dir / "post-start-rootless-trace.log").read_text(encoding="utf-8").splitlines()
        self.assertEqual(
            ["lifecycle-locked", "compose-pulled", "rootless-locked", "rootless-unlocked", "lifecycle-unlocked", "lifecycle-locked", "lifecycle-unlocked"],
            trace,
        )

    def test_compose_pull_runs_before_rootless_lifecycle_lock(self):
        trace_log = self.compose_dir / "pre-pull-trace.log"
        metadata = self.write_service_metadata(
            "metadata-pre-pull-before-rootless-lock.json",
        )

        self.run_helper(
            """
            podman_compose_metadata=$NIX_PODMAN_COMPOSE_METADATA
            load_metadata
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            clear_removal_policy_marker() { :; }
            stage_runtime_files() { :; }
            record_staging_runtime_state() { :; }
            run_pre_start_hooks() { :; }
            clear_start_in_progress() { :; }
            compose_up_checked() { printf 'compose-started\n'; }
            compose_pull() { printf 'compose-pulled\n' >> "$working_dir/pre-pull-trace.log"; }
            record_runtime_state() { printf 'state-recorded\n'; }
            podman_rootless_lifecycle_lock() {
              if [ "$podman_rootless_lifecycle_lock_depth" -gt 0 ]; then
                podman_rootless_lifecycle_lock_depth=$((podman_rootless_lifecycle_lock_depth + 1))
                return 0
              fi
              printf 'rootless-locked\n' >> "$working_dir/pre-pull-trace.log"
              podman_rootless_lifecycle_lock_depth=1
            }
            podman_rootless_lifecycle_unlock() {
              if [ "$podman_rootless_lifecycle_lock_depth" -le 0 ]; then
                return 0
              fi
              podman_rootless_lifecycle_lock_depth=$((podman_rootless_lifecycle_lock_depth - 1))
              if [ "$podman_rootless_lifecycle_lock_depth" -gt 0 ]; then
                return 0
              fi
              printf 'rootless-unlocked\n' >> "$working_dir/pre-pull-trace.log"
            }
            notify_ready_and_monitor() { :; }
            cmd_start
            """,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_TIMEOUT_VALUE="5s",
        )

        trace = (self.compose_dir / "pre-pull-trace.log").read_text(encoding="utf-8").splitlines()
        pull_index = trace.index("compose-pulled")
        lock_index = trace.index("rootless-locked")
        self.assertLess(pull_index, lock_index, "compose_pull must run before rootless lifecycle lock")

    def test_start_staged_does_not_pull_images_inline(self):
        trace_log = self.compose_dir / "start-staged-no-pull-trace.log"
        metadata = self.write_service_metadata(
            "metadata-start-staged-no-pull.json",
        )

        self.run_helper(
            """
            podman_compose_metadata=$NIX_PODMAN_COMPOSE_METADATA
            load_metadata
            assert_adoption_allowed() { :; }
            ensure_runtime_dirs() { :; }
            clear_removal_policy_marker() { :; }
            clear_start_in_progress() { :; }
            verify_staged_runtime_files() { :; }
            compose_start_plan_locked() { printf 'normal\t0\n'; }
            compose_pull() { printf 'compose-pulled\n' >> "$working_dir/start-staged-no-pull-trace.log"; return 1; }
            compose_up_checked() { printf 'compose-started\n' >> "$working_dir/start-staged-no-pull-trace.log"; }
            record_runtime_state() { printf 'state-recorded\n' >> "$working_dir/start-staged-no-pull-trace.log"; }
            lock_lifecycle_exclusive() { printf 'lifecycle-locked\n' >> "$working_dir/start-staged-no-pull-trace.log"; }
            unlock_lifecycle_exclusive() { printf 'lifecycle-unlocked\n' >> "$working_dir/start-staged-no-pull-trace.log"; }
            notify_ready_and_monitor() { :; }
            cmd_start_staged
            """,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_TIMEOUT_VALUE="5s",
        )

        trace = trace_log.read_text(encoding="utf-8").splitlines()
        self.assertNotIn("compose-pulled", trace)
        self.assertIn("compose-started", trace)
        self.assertIn("state-recorded", trace)

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

    def test_assert_adoption_allowed_bootstraps_legacy_helper_state(self):
        metadata = self.write_metadata(
            "metadata-adoption-legacy.json",
            {
                "adoptionStamp": "test-adoption-stamp",
                "reconcilePolicy": "auto",
                "restartStamp": "restart-new",
                "recreateTag": "1",
                "recreateStamp": "recreate-new",
                "recreateClassStamp": "class-new",
            },
        )
        self.generated_dir.mkdir()
        (self.generated_dir / "lifecycle.lock").touch()
        (self.compose_dir / "data").mkdir()

        result = self.run_helper(
            f"""
            podman_compose_metadata={metadata}
            adoption_stamp=test-adoption-stamp
            reconcile_policy=auto
            restart_stamp=restart-new
            recreate_tag=1
            recreate_stamp=recreate-new
            recreate_class_stamp=class-new
            assert_adoption_allowed
            """
        )

        self.assertIn("Bootstrapping missing Podman compose helper state", result.stdout)
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(3, state["version"])
        self.assertEqual("test-adoption-stamp", state["adoptionStamp"])
        self.assertEqual("auto", state["reconcilePolicy"])
        self.assertEqual("restart-new", state["restartStamp"])
        self.assertEqual("1", state["recreateTag"])
        self.assertEqual("recreate-new", state["recreateStamp"])
        self.assertEqual("class-new", state["recreateClassStamp"])

    def test_assert_adoption_allowed_migrates_compatible_old_runtime_state(self):
        metadata = self.write_metadata(
            "metadata-adoption-old-runtime-state.json",
            {
                "adoptionStamp": "test-adoption-stamp",
                "reconcilePolicy": "auto",
                "restartStamp": "restart-new",
            },
        )
        self.write_runtime_state(version=1, restartStamp="restart-old", startupPhase="staging")

        self.run_helper(
            f"""
            podman_compose_metadata={metadata}
            adoption_stamp=test-adoption-stamp
            reconcile_policy=auto
            restart_stamp=restart-new
            assert_adoption_allowed
            """
        )

        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(3, state["version"])
        self.assertEqual("test-adoption-stamp", state["adoptionStamp"])
        self.assertEqual("restart-new", state["restartStamp"])
        self.assertNotIn("startupPhase", state)

    def test_assert_adoption_allowed_refuses_unexpected_file_in_helper_shell(self):
        metadata = self.write_metadata("metadata-adoption-extra-file.json", {})
        self.generated_dir.mkdir()
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
        self.assertEqual(3, state["version"])
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

    def test_runtime_state_version_migration_refreshes_restart_stamp(self):
        self.write_runtime_state(version=1, restartStamp="old-restart", startupPhase="staging")

        self.run_helper(
            """
            adoption_stamp=test-adoption-stamp
            reconcile_policy=auto
            restart_stamp=new-restart
            verify_runtime_state_current
            """
        )

        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(3, state["version"])
        self.assertEqual("new-restart", state["restartStamp"])
        self.assertEqual("auto", state["reconcilePolicy"])
        self.assertNotIn("startupPhase", state)

    def test_runtime_state_verification_bootstraps_legacy_helper_state(self):
        self.generated_dir.mkdir()
        (self.generated_dir / "lifecycle.lock").touch()
        (self.compose_dir / "data").mkdir()

        result = self.run_helper(
            """
            adoption_stamp=test-adoption-stamp
            reconcile_policy=auto
            restart_stamp=restart-new
            recreate_tag=1
            recreate_stamp=recreate-new
            recreate_class_stamp=class-new
            verify_runtime_state_current
            """
        )

        self.assertIn("Bootstrapping missing Podman compose helper state", result.stdout)
        self.assertNotIn("restart-class metadata is not applied", result.stderr)
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual("restart-new", state["restartStamp"])
        self.assertEqual("recreate-new", state["recreateStamp"])

    def test_cmd_verify_rejects_active_start_pid(self):
        metadata = self.write_service_metadata("metadata-active-start-verify.json")
        self.generated_dir.mkdir()
        result = self.run_helper(
            """
            sleep 10 &
            sleep_pid=$!
            printf 'pid=%s\nstartedAt=1\n' "$sleep_pid" >"$generated_dir/start-in-progress"
            cmd_verify
            kill "$sleep_pid" 2>/dev/null || true
            """,
            check=False,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("podman compose start is still in progress", result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8")
        self.assertNotIn("compose ps --format json", history)

    def test_cmd_start_adopts_active_start_before_lifecycle_lock(self):
        metadata = self.write_service_metadata(
            "metadata-active-start-before-lock-start.json",
        )
        monitor_wrapper = self.state_dir / "monitor-wrapper"
        self._write_executable(
            monitor_wrapper,
            textwrap.dedent(
                f'''#!{shutil.which("bash")}
                printf 'monitor:%s\n' "$*"
                '''
            ).lstrip(),
        )

        result = self.run_helper(
            """
            install -d -m 0750 "$generated_dir"
            sleep 10 </dev/null >/dev/null 2>&1 &
            start_pid=$!
            printf 'pid=%s\nstartedAt=1\n' "$start_pid" >"$generated_dir/start-in-progress"
            (
              exec 8>"$lifecycle_lock_path"
              flock -x 8
              sleep 5
            ) </dev/null >/dev/null 2>&1 &
            holder_pid="$!"
            trap 'kill "$holder_pid" "$start_pid" 2>/dev/null || true' EXIT
            sleep 0.2
            cmd_start
            """,
            timeout=10,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            NIX_PODMAN_COMPOSE_HELPER_TOPLEVEL="1",
            NIX_PODMAN_COMPOSE_HELPER_SELF=str(monitor_wrapper),
            XDG_RUNTIME_DIR=str(self.runtime_dir),
        )
        self.assertIn(
            "--ready --status=podman compose start already in progress",
            self.systemd_notify_history_file.read_text(encoding="utf-8"),
        )
        history = self.podman_history_file.read_text(encoding="utf-8")
        self.assertNotIn("compose up", history)

    def test_cmd_post_stop_skips_cleanup_for_active_start_pid(self):
        metadata = self.write_service_metadata(
            "metadata-active-start-before-lock-post-stop.json",
        )

        result = self.run_helper(
            """
            install -d -m 0750 "$generated_dir"
            sleep 10 &
            start_pid=$!
            printf 'pid=%s\nstartedAt=1\n' "$start_pid" >"$generated_dir/start-in-progress"
            (
              exec 8>"$lifecycle_lock_path"
              flock -x 8
              sleep 5
            ) &
            holder_pid="$!"
            trap 'kill "$holder_pid" "$start_pid" 2>/dev/null || true; wait "$holder_pid" "$start_pid" 2>/dev/null || true' EXIT
            sleep 0.2
            cmd_post_stop
            """,
            timeout=2,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
        )

        self.assertIn(
            "podman compose start is in progress; skipping post-stop cleanup for test-compose",
            result.stdout,
        )
        history = self.podman_history_file.read_text(encoding="utf-8")
        self.assertNotIn("compose down", history)

    def test_cmd_verify_rejects_main_unit_transition(self):
        metadata, staged_config, _data_dir = self.write_staged_service_metadata(
            "metadata-main-unit-transition-verify.json"
        )
        self.write_runtime_state()
        self.assertFalse(staged_config.exists())

        transitioning = self.run_helper(
            "cmd_verify",
            check=False,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_SYSTEMCTL_JOB="123/start",
        )

        self.assertNotEqual(0, transitioning.returncode)
        self.assertIn("podman compose unit is still transitioning", transitioning.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8")
        self.assertNotIn("compose ps --format json", history)

        stable = self.run_helper(
            "cmd_verify",
            check=False,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
        )

        self.assertNotEqual(0, stable.returncode)
        self.assertIn("podman compose staged file is missing", stable.stderr)

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

    def test_monitor_compose_state_tolerates_transient_non_running_container(self):
        self.run_helper(
            """
            monitor_interval=1
            compose_monitor_failure_grace_seconds=5
            long_running=true
            expected_compose_services=()
            verify_staged_runtime_files() { return 0; }
            verify_runtime_state_current() { return 0; }
            call_count=0
            compose_state_json() {
              call_count="$((call_count + 1))"
              if [ "$call_count" -eq 1 ]; then
                printf '%s\n' '[{"State":"exited","ExitCode":1,"Names":["test_web_1"]}]'
              else
                printf '%s\n' '[{"State":"running","Names":["test_web_1"]}]'
              fi
            }
            monitor_compose_state &
            monitor_pid="$!"
            sleep 3
            if ! kill -0 "$monitor_pid" 2>/dev/null; then
              wait "$monitor_pid"
              exit 1
            fi
            kill "$monitor_pid"
            wait "$monitor_pid" 2>/dev/null || true
            """,
            timeout=8,
        )

    def test_monitor_compose_state_ignores_live_source_drift_for_staged_files(self):
        src_config = self.state_dir / "live-source.yml"
        staged_config = self.compose_dir / "config" / "service.yml"
        src_config.write_text("generation = 2\n", encoding="utf-8")
        staged_config.parent.mkdir(parents=True)
        staged_config.write_text("generation = 1\n", encoding="utf-8")
        metadata = self.write_metadata(
            "metadata-monitor-source-drift.json",
            {
                "workingDir": str(self.compose_dir),
                "adoptionStamp": "test-adoption-stamp",
                "state": "running",
                "reconcilePolicy": "auto",
                "removalPolicy": "delete",
                "longRunning": True,
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
            },
        )

        self.run_helper(
            f"""
            podman_compose_metadata={metadata}
            monitor_interval=1
            compose_monitor_failure_grace_seconds=1
            long_running=true
            expected_compose_services=()
            verify_runtime_state_current() {{ return 0; }}
            compose_state_json() {{
              printf '%s\n' '[{{"State":"running","Names":["test_web_1"]}}]'
            }}
            monitor_compose_state &
            monitor_pid="$!"
            sleep 2
            if ! kill -0 "$monitor_pid" 2>/dev/null; then
              wait "$monitor_pid"
              exit 1
            fi
            kill "$monitor_pid"
            wait "$monitor_pid" 2>/dev/null || true
            """,
            timeout=8,
        )

    def test_monitor_compose_state_fails_after_transient_grace(self):
        result = self.run_helper(
            """
            monitor_interval=1
            compose_monitor_failure_grace_seconds=1
            long_running=true
            expected_compose_services=()
            verify_staged_runtime_files() { return 0; }
            verify_runtime_state_current() { return 0; }
            compose_state_json() {
              printf '%s\n' '[{"State":"exited","ExitCode":1,"Names":["test_web_1"]}]'
            }
            monitor_compose_state
            """,
            check=False,
            timeout=8,
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("retrying for up to 1s", result.stderr)
        self.assertIn("podman compose monitor detected a non-running container state", result.stderr)

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
        self.assertIn("rm -f --depend -v abc123", history)
        self.assertIn("rm -f --depend -v compose_web_1", history)
        self.assertIn("rm -f --depend -v compose_worker_1", history)

    def test_remove_compose_project_containers_removes_storage_names(self):
        self.run_helper(
            """
            expected_compose_services=(web)
            remove_compose_project_containers
            """,
            TEST_PODMAN_MODE="storage_container",
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("rm -f --depend -v compose_web_1", history)
        self.assertIn("rm --storage --force compose_web_1", history)

    def test_remove_compose_project_containers_cleans_opaque_storage_names(self):
        compose_file = self.compose_dir / "compose.yml"
        compose_file.write_text("services:\n  api:\n    image: example\n", encoding="utf-8")
        self.run_helper(
            """
            compose_file_args=(-f compose.yml)
            expected_compose_services=()
            start_in_progress_path="${generated_dir}/start-in-progress"
            ensure_runtime_dirs
            mark_start_in_progress
            remove_compose_project_containers
            """,
            TEST_PODMAN_STORAGE_NAMES="compose_api_1",
            TEST_PODMAN_MODE="storage_container",
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("container list --all --storage --format {{.Names}}", history)
        self.assertIn("rm -f --depend -v compose_api_1", history)
        self.assertIn("rm --storage --force compose_api_1", history)

    def test_remove_compose_project_containers_unmounts_mounted_names(self):
        self.run_helper(
            """
            expected_compose_services=(web)
            remove_compose_project_containers
            """,
            TEST_PODMAN_MODE="mounted_container",
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("rm -f --depend -v compose_web_1", history)
        self.assertIn("unmount --force compose_web_1", history)
        self.assertEqual(2, history.count("rm -f --depend -v compose_web_1"))

    def test_remove_compose_project_containers_cleans_stale_storage_mountpoint(self):
        mountpoint = self.work_dir / ".local/share/containers/storage/overlay/layer/merged"
        stale_entry = mountpoint / "proc"
        stale_entry.mkdir(parents=True)

        self.run_helper(
            """
            expected_compose_services=(web)
            remove_compose_project_containers
            """,
            HOME=str(self.work_dir),
            TEST_PODMAN_MODE="mounted_storage_container",
            TEST_PODMAN_STORAGE_MOUNTPOINT=str(mountpoint),
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("unmount --force compose_web_1", history)
        self.assertIn("rm --storage --force compose_web_1", history)
        self.assertEqual(2, history.count("rm --storage --force compose_web_1"))
        self.assertFalse(stale_entry.exists())

    def test_remove_conflicting_compose_container_names_removes_storage_names(self):
        self.run_helper(
            """
            expected_compose_services=(web)
            remove_conflicting_compose_container_names
            """,
            TEST_PODMAN_MODE="storage_container",
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("container exists compose_web_1", history)
        self.assertIn("rm -f --depend -v compose_web_1", history)
        self.assertIn("rm --storage --force compose_web_1", history)

    def test_disable_compose_restart_policies_updates_live_ids_and_expected_names(self):
        self.run_helper(
            """
            expected_compose_services=(web worker)
            disable_compose_project_restart_policies
            """,
            TEST_PODMAN_PS_IDS="abc123",
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("ps -a --filter label=com.docker.compose.project.working_dir=" + str(self.compose_dir) + " --format {{.ID}}", history)
        self.assertIn("update --restart=no abc123 compose_web_1 compose_worker_1", history)

    def test_cmd_stop_disables_restart_policy_before_compose_down(self):
        metadata = self.write_service_metadata(
            "metadata-stop-restart-policy.json",
            expectedComposeServices=["web"],
        )

        self.run_helper(
            "cmd_stop",
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_PODMAN_PS_IDS="abc123",
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("update --restart=no abc123 compose_web_1", history)
        self.assertLess(history.index("update --restart=no abc123 compose_web_1"), history.index("compose down"))

    def test_cmd_stop_timeout_runs_direct_container_cleanup(self):
        metadata = self.write_service_metadata(
            "metadata-stop-timeout-cleanup.json",
            expectedComposeServices=["web"],
        )
        child_pid_file = self.state_dir / "cmd-stop-child.pid"

        result = self.run_helper(
            "cmd_stop",
            check=False,
            timeout=20,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_PODMAN_MODE="down_timeout_child",
            TEST_TIMEOUT_VALUE="2s",
            TEST_PODMAN_CHILD_PID_FILE=str(child_pid_file),
            TEST_PODMAN_PS_IDS="abc123",
        )

        self.assertEqual(0, result.returncode)
        self.assert_child_process_was_cleaned_up(child_pid_file)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("compose down", history)
        self.assertIn("rm -f --depend -v abc123", history)
        self.assertIn("rm -f --depend -v compose_web_1", history)

    def test_cmd_stop_policy_stop_timeout_remains_failure(self):
        metadata = self.write_service_metadata(
            "metadata-stop-policy-timeout.json",
            expectedComposeServices=["web"],
            removalPolicy="stop",
        )
        self.write_runtime_state(removalPolicy="stop")
        child_pid_file = self.state_dir / "cmd-stop-policy-child.pid"

        result = self.run_helper(
            "cmd_stop",
            check=False,
            timeout=20,
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            TEST_PODMAN_MODE="stop_timeout_child",
            TEST_TIMEOUT_VALUE="2s",
            TEST_PODMAN_CHILD_PID_FILE=str(child_pid_file),
            TEST_PODMAN_PS_IDS="abc123",
        )

        self.assertNotEqual(0, result.returncode)
        self.assert_child_process_was_cleaned_up(child_pid_file)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("compose stop", history)
        self.assertNotIn("rm -f --depend -v abc123", history)
        self.assertNotIn("rm -f --depend -v compose_web_1", history)

    def test_remove_compose_project_containers_removes_anonymous_volumes(self):
        anonymous_volume = "a" * 64

        self.run_helper(
            """
            expected_compose_services=(web)
            remove_compose_project_containers
            """,
            TEST_PODMAN_PS_IDS="abc123",
            TEST_PODMAN_INSPECT_MOUNTS_JSON=json.dumps(
                [
                    {"Type": "volume", "Name": anonymous_volume},
                    {"Type": "volume", "Name": "named-data"},
                    {"Type": "bind", "Name": ""},
                ]
            ),
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn(f"volume rm {anonymous_volume}", history)
        self.assertNotIn("volume rm named-data", history)

    def test_compose_down_removes_recorded_anonymous_volumes(self):
        anonymous_volume = "b" * 64

        self.run_helper(
            """
            expected_compose_services=(web)
            compose_down
            """,
            TEST_PODMAN_PS_IDS="abc123",
            TEST_PODMAN_INSPECT_MOUNTS_JSON=json.dumps(
                [{"Type": "volume", "Name": anonymous_volume}]
            ),
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        inspect_index = history.index("inspect abc123 --format {{json .Mounts}}")
        down_index = history.index("compose down")
        volume_index = history.index(f"volume rm {anonymous_volume}")
        self.assertLess(inspect_index, down_index)
        self.assertLess(down_index, volume_index)

    def test_remove_container_target_fails_when_podman_rm_leaves_name(self):
        result = self.run_helper(
            "remove_container_target compose_web_1",
            check=False,
            TEST_PODMAN_MODE="rm_zero_leaves_exists",
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("podman container compose_web_1 still exists after removal", result.stderr)
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("rm -f --depend -v compose_web_1", history)
        self.assertIn("container cleanup --rm compose_web_1", history)
        self.assertIn("container exists compose_web_1", history)

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
        self.assertTrue(staged_config.exists())
        self.assertTrue(data_dir.exists())
        self.assertEqual("staging", json.loads(self.state_path.read_text(encoding="utf-8"))["startupPhase"])
        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("compose up --no-build -d --remove-orphans", history)
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
        (self.compose_dir / ".podman-compose").mkdir(exist_ok=True)
        (self.compose_dir / ".podman-compose" / "start-in-progress").write_text("pid=999999\n", encoding="utf-8")

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
        self.assertTrue(staged_config.exists())
        self.assertTrue(data_dir.exists())
        self.assertEqual("staging", json.loads(self.state_path.read_text(encoding="utf-8"))["startupPhase"])
        self.assertEqual(
            [
                "ps -a --filter label=com.docker.compose.project.working_dir="
                + str(self.compose_dir)
                + " --format {{.ID}}",
                "container list --all --storage --format {{.Names}}",
                "compose down",
                "ps -a --filter label=com.docker.compose.project.working_dir="
                + str(self.compose_dir)
                + " --format {{.ID}}",
                "container list --all --storage --format {{.Names}}",
            ],
            self.podman_history_file.read_text(encoding="utf-8").splitlines(),
        )

    def test_cmd_post_stop_failed_stop_runs_direct_cleanup_backstop(self):
        metadata = self.write_service_metadata(
            "metadata-post-stop-failed-stop.json",
            expectedComposeServices=["web"],
        )
        stop_marker = self.compose_dir / ".podman-compose" / "stop-in-progress"
        stop_marker.parent.mkdir(exist_ok=True)
        stop_marker.write_text("pid=1\n", encoding="utf-8")

        result = self.run_helper(
            "cmd_post_stop",
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            SERVICE_RESULT="timeout",
            TEST_PODMAN_PS_IDS="abc123",
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("rm -f --depend -v abc123", history)
        self.assertIn("rm -f --depend -v compose_web_1", history)

    def test_cmd_post_stop_failed_start_does_not_run_failed_stop_cleanup(self):
        metadata, staged_config, data_dir = self.write_staged_service_metadata(
            "metadata-post-stop-failed-start-no-stop-cleanup.json",
            expectedComposeServices=["web"],
        )
        staged_config.parent.mkdir(parents=True)
        staged_config.write_text("key: value\n", encoding="utf-8")
        data_dir.mkdir()
        self.manifest_path.parent.mkdir(parents=True)
        self.manifest_path.write_text(str(staged_config) + "\n", encoding="utf-8")
        self.write_runtime_state(startupPhase="staging")
        (self.compose_dir / ".podman-compose").mkdir(exist_ok=True)
        (self.compose_dir / ".podman-compose" / "start-in-progress").write_text("pid=999999\n", encoding="utf-8")

        result = self.run_helper(
            "cmd_post_stop",
            NIX_PODMAN_COMPOSE_METADATA=str(metadata),
            NIX_PODMAN_COMPOSE_SERVICE_NAME="test-compose",
            XDG_RUNTIME_DIR=str(self.runtime_dir),
            SERVICE_RESULT="exit-code",
            TEST_PODMAN_MODE="success",
            TEST_TIMEOUT_VALUE="5s",
            TEST_PODMAN_PS_IDS="abc123",
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertIn("compose down", history)
        self.assertIn("systemd reported test-compose.service result=exit-code; running failed-start cleanup", result.stdout)
        self.assertNotIn("failed-stop cleanup", result.stdout)

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
        self.assertEqual(
            [
                "ps -a --filter label=com.docker.compose.project.working_dir="
                + str(self.compose_dir)
                + " --format {{.ID}}",
                "compose down",
            ],
            history,
        )

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
        self.assertIn("compose up --no-build -d --remove-orphans", history)
        self.assertNotIn("compose up --no-build -d --remove-orphans --force-recreate", history)
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
        self.assertIn("compose up --no-build -d --remove-orphans", history)
        self.assertNotIn("compose up --no-build -d --remove-orphans --force-recreate", history)
        self.assertIn("marked running but runtime pid 999999999 is not present", result.stderr)
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual("recreate-a", state["recreateStamp"])
        self.assertEqual("class-a", state["recreateClassStamp"])

    def test_cmd_start_force_recreates_partial_long_running_project(self):
        metadata = self.write_service_metadata(
            "metadata-partial-project-start.json",
            adopt=False,
            reconcilePolicy="auto",
            restartStamp="restart-a",
            recreateTag="0",
            recreateStamp="recreate-a",
            recreateClassStamp="class-a",
            expectedComposeServices=["web", "worker"],
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
            TEST_PODMAN_COMPOSE_PS_JSON=json.dumps(
                [
                    {
                        "State": "running",
                        "Labels": {"io.podman.compose.service": "web"},
                        "Names": ["compose_web_1"],
                    },
                    {
                        "State": "exited",
                        "ExitCode": 135,
                        "Status": "Exited (135)",
                        "Labels": {"io.podman.compose.service": "worker"},
                        "Names": ["compose_worker_1"],
                    },
                ]
            ),
            TEST_PODMAN_COMPOSE_PS_JSON_AFTER_UP=json.dumps(
                [
                    {
                        "State": "running",
                        "Labels": {"io.podman.compose.service": "web"},
                        "Names": ["compose_web_1"],
                    },
                    {
                        "State": "running",
                        "Labels": {"io.podman.compose.service": "worker"},
                        "Names": ["compose_worker_1"],
                    },
                ]
            ),
            TEST_PODMAN_PS_JSON=json.dumps(
                [
                    {
                        "ID": "web123",
                        "Labels": {"io.podman.compose.service": "web"},
                    },
                    {
                        "ID": "worker123",
                        "Labels": {"io.podman.compose.service": "worker"},
                    },
                ]
            ),
            check=False,
        )

        history = self.podman_history_file.read_text(encoding="utf-8").splitlines()
        self.assertEqual(0, result.returncode, result.stderr + "\n" + "\n".join(history))
        self.assertIn("podman compose project has non-running containers before start", result.stderr)
        self.assertIn("compose_worker_1: state=exited exit=135", result.stderr)
        self.assertIn("rm -f --depend -v compose_web_1", history)
        self.assertIn("rm -f --depend -v compose_worker_1", history)
        self.assert_compose_up_in_history(history)
        self.assert_compose_force_recreate_not_in_history(history)
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual("recreate-a", state["recreateStamp"])
        self.assertEqual("class-a", state["recreateClassStamp"])


if __name__ == "__main__":
    unittest.main()
