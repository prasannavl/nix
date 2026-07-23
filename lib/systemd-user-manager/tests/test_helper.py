import base64
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import textwrap
import time
import unittest
from pathlib import Path


class SystemdUserManagerHelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[3]
        cls.helper = cls.repo_root / "lib/systemd-user-manager/helper.sh"
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def setUp(self):
        self.work_dir = Path(tempfile.mkdtemp(prefix="systemd-user-manager-helper-test.", dir=self.tmp_root))
        self.fake_bin = self.work_dir / "bin"
        self.state_dir = self.work_dir / "state"
        self.fake_bin.mkdir()
        self.state_dir.mkdir()
        self._write_executable(self.fake_bin / "id", "#!/bin/sh\nprintf '1001\\n'\n")
        self._write_executable(self.fake_bin / "chown", "#!/bin/sh\nexit 0\n")

    def tearDown(self):
        shutil.rmtree(self.work_dir)

    def _write_executable(self, path: Path, body: str):
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def write_fake_setpriv(self):
        self._write_executable(
            self.fake_bin / "setpriv",
            """#!/bin/sh
while [ "$#" -gt 0 ]; do
  if [ "$1" = "env" ]; then
    exec "$@"
  fi
  shift
done
exit 127
""",
        )

    def write_fake_systemctl(self):
        log_path = shlex.quote(str(self.state_dir / "systemctl.log"))
        systemctl_state_dir = shlex.quote(str(self.state_dir / "systemctl-state"))
        self._write_executable(
            self.fake_bin / "systemctl",
            f"""#!/bin/sh
set -eu
log={log_path}
state_dir={systemctl_state_dir}
mkdir -p "$state_dir"
printf '%s\\n' "$*" >> "$log"

unit_key() {{
  printf '%s' "$1" | tr '/ ' '__'
}}

unit_state_file() {{
  printf '%s/%s.active' "$state_dir" "$(unit_key "$1")"
}}

active_state_for() {{
  sequence_file="$state_dir/active-sequence"
  if [ -s "$sequence_file" ]; then
    IFS= read -r state < "$sequence_file"
    tail -n +2 "$sequence_file" > "$sequence_file.tmp"
    mv "$sequence_file.tmp" "$sequence_file"
    printf '%s\\n' "$state"
    return 0
  fi
  state_file="$(unit_state_file "$1")"
  if [ -f "$state_file" ]; then
    cat "$state_file"
  else
    printf '%s\\n' "active"
  fi
}}

if [ "${{1-}}" = "is-active" ]; then
  exit 0
fi

if [ "${{1-}}" = "--user" ]; then
  shift
fi
if [ "${{1-}}" = "--no-block" ]; then
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
	      ActiveState) active_state_for "$unit" ;;
	      LoadState) printf '%s\\n' "loaded" ;;
	      SubState) printf '%s\\n' "dead" ;;
	      Result) printf '%s\\n' "${{FAKE_SYSTEMCTL_RESULT:-success}}" ;;
	      ExecMainCode) printf '%s\\n' "${{FAKE_SYSTEMCTL_EXEC_MAIN_CODE:-exited}}" ;;
	      ExecMainStatus) printf '%s\\n' "${{FAKE_SYSTEMCTL_EXEC_MAIN_STATUS:-0}}" ;;
	      Type) printf '%s\\n' "${{FAKE_SYSTEMCTL_SERVICE_TYPE:-simple}}" ;;
	      NRestarts) printf '%s\\n' "0" ;;
	      UnitFileState) printf '%s\\n' "enabled" ;;
	      InvocationID) printf '%s\\n' "fake-invocation" ;;
      *) printf '%s\\n' "" ;;
    esac
    ;;
	  stop)
	    if [ -n "${{FAKE_SYSTEMCTL_STOP_SLEEP-}}" ]; then
	      sleep "$FAKE_SYSTEMCTL_STOP_SLEEP"
	    fi
	    printf '%s\\n' "${{FAKE_SYSTEMCTL_STOP_STATE:-inactive}}" > "$(unit_state_file "$1")"
	    ;;
  reset-failed)
    printf '%s\\n' "inactive" > "$(unit_state_file "$1")"
    ;;
  kill)
    if [ -n "${{FAKE_SYSTEMCTL_KILL_STATE-}}" ]; then
      unit=""
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --*) ;;
          *) unit="$1" ;;
        esac
        shift
      done
      printf '%s\\n' "$FAKE_SYSTEMCTL_KILL_STATE" > "$(unit_state_file "$unit")"
    fi
    ;;
  restart)
    if [ "${{FAKE_SYSTEMCTL_RESTART_FAIL-0}}" = 1 ]; then
      exit 1
    fi
    printf '%s\\n' "active" > "$(unit_state_file "$1")"
    ;;
  start)
    if [ -n "${{FAKE_SYSTEMCTL_START_STATE-}}" ]; then
      printf '%s\\n' "$FAKE_SYSTEMCTL_START_STATE" > "$(unit_state_file "$1")"
    fi
    if [ "${{FAKE_SYSTEMCTL_START_FAIL-0}}" = 1 ]; then
      exit 1
    fi
    ;;
  reload|daemon-reload)
    ;;
  *)
    ;;
esac
""",
        )

    def helper_env(self, **overrides):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.fake_bin}:{env['PATH']}",
                "SYSTEMD_USER_MANAGER_APPLIED_METADATA_DIR": str(self.state_dir / "applied"),
                "SYSTEMD_USER_MANAGER_DEFERRED_RESTART_REQUEST_DIR": str(self.state_dir / "manager-restarts"),
                "SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RESTART_REQUEST_DIR": str(self.state_dir / "unit-restarts"),
                "SYSTEMD_USER_MANAGER_DEFERRED_UNIT_RELOAD_REQUEST_DIR": str(self.state_dir / "unit-reloads"),
                "SYSTEMD_USER_MANAGER_MANAGED_USER_ACTION_PATH": f"{self.fake_bin}:{env['PATH']}",
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
            export PATH
            {body}
            """
        )

    def run_helper(self, body: str, *, check=True, **env_overrides):
        return subprocess.run(
            ["bash", "-c", self.helper_script(body)],
            cwd=self.repo_root,
            env=self.helper_env(**env_overrides),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def write_metadata(self, name: str, metadata: dict) -> Path:
        path = self.state_dir / name
        path.write_text(json.dumps(metadata), encoding="utf-8")
        return path

    def test_start_concurrency_accepts_unlimited_sentinel(self):
        result = self.run_helper(
            'printf "%s\n" "$start_concurrency"',
            SYSTEMD_USER_MANAGER_START_CONCURRENCY="-1",
        )

        self.assertEqual("-1\n", result.stdout)

    def encoded_command(self, command):
        return base64.b64encode(json.dumps(command).encode()).decode()

    def test_apply_mode_marks_restart_reload_and_runs_removal_command(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        removal_log = self.state_dir / "removal.log"
        self._write_executable(
            self.fake_bin / "remove-managed-unit",
            f"#!/bin/sh\nprintf '%s\\n' \"$*\" >> {shlex.quote(str(removal_log))}\n",
        )
        old_metadata = self.write_metadata(
            "apply-old.json",
            {
                "version": 5,
                "user": "alice",
                "identityStamp": "same",
                "managedUnits": [
                    {
                        "name": "restart",
                        "unit": "restart.service",
                        "removalPolicy": "stop",
                        "stamp": "old-restart",
                        "reloadStamp": "same",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                    {
                        "name": "reload",
                        "unit": "reload.service",
                        "removalPolicy": "stop",
                        "stamp": "same",
                        "reloadStamp": "old-reload",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                    {
                        "name": "removed",
                        "unit": "removed.service",
                        "removalPolicy": "stop",
                        "removalCommand": ["remove-managed-unit", "removed"],
                        "stamp": "removed",
                    },
                ],
            },
        )
        new_metadata = self.write_metadata(
            "apply-new.json",
            {
                "version": 5,
                "user": "alice",
                "identityStamp": "same",
                "managedUnits": [
                    {
                        "name": "restart",
                        "unit": "restart.service",
                        "removalPolicy": "stop",
                        "stamp": "new-restart",
                        "reloadStamp": "same",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                    {
                        "name": "reload",
                        "unit": "reload.service",
                        "removalPolicy": "stop",
                        "stamp": "same",
                        "reloadStamp": "new-reload",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        self.run_helper(
            f"""
            init_managed_user alice
            old_tsv="$(read_metadata_stop_state_tsv {old_metadata})"
            new_tsv="$(read_metadata_stop_state_tsv {new_metadata})"
            diff_and_stop_units apply alice "$old_tsv" "$new_tsv"
            """
        )

        self.assertEqual(
            "restart\n",
            (self.state_dir / "unit-restarts/alice/restart").read_text(encoding="utf-8"),
        )
        self.assertEqual(
            "new-reload\n",
            (self.state_dir / "unit-reloads/alice/reload").read_text(encoding="utf-8"),
        )
        self.assertEqual("removed\n", removal_log.read_text(encoding="utf-8"))
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user --no-block stop restart.service", systemctl_log)
        self.assertNotIn("--user --no-block stop removed.service", systemctl_log)

    def test_apply_mode_stops_changed_units_concurrently(self):
        self.write_fake_systemctl()
        old_metadata = self.write_metadata(
            "parallel-old.json",
            {
                "version": 5,
                "user": "alice",
                "identityStamp": "same",
                "managedUnits": [
                    {
                        "name": "alpha",
                        "unit": "alpha.service",
                        "removalPolicy": "stop",
                        "stamp": "old-alpha",
                        "timeoutReadySeconds": 5,
                    },
                    {
                        "name": "beta",
                        "unit": "beta.service",
                        "removalPolicy": "stop",
                        "stamp": "old-beta",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )
        new_metadata = self.write_metadata(
            "parallel-new.json",
            {
                "version": 5,
                "user": "alice",
                "identityStamp": "same",
                "managedUnits": [
                    {
                        "name": "alpha",
                        "unit": "alpha.service",
                        "removalPolicy": "stop",
                        "stamp": "new-alpha",
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                    {
                        "name": "beta",
                        "unit": "beta.service",
                        "removalPolicy": "stop",
                        "stamp": "new-beta",
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        started = time.monotonic()
        self.run_helper(
            f"""
            init_managed_user alice
            old_tsv="$(read_metadata_stop_state_tsv {old_metadata})"
            new_tsv="$(read_metadata_stop_state_tsv {new_metadata})"
            diff_and_stop_units apply alice "$old_tsv" "$new_tsv"
            """,
            FAKE_SYSTEMCTL_STOP_SLEEP="0.6",
        )
        elapsed = time.monotonic() - started

        self.assertLess(elapsed, 1.1)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user --no-block stop alpha.service", systemctl_log)
        self.assertIn("--user --no-block stop beta.service", systemctl_log)

    def test_apply_marks_changed_failed_units_for_restart(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("failed\n", encoding="utf-8")
        old_metadata = self.write_metadata(
            "failed-restart-old.json",
            {
                "version": 5,
                "user": "alice",
                "identityStamp": "same",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "removalPolicy": "stop",
                        "stamp": "old-web",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )
        new_metadata = self.write_metadata(
            "failed-restart-new.json",
            {
                "version": 5,
                "user": "alice",
                "identityStamp": "same",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "removalPolicy": "stop",
                        "stamp": "new-web",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            f"""
            init_managed_user alice
            old_tsv="$(read_metadata_stop_state_tsv {old_metadata})"
            new_tsv="$(read_metadata_stop_state_tsv {new_metadata})"
            diff_and_stop_units apply alice "$old_tsv" "$new_tsv"
            consume_deferred_managed_unit_restart alice web
            """
        )

        self.assertEqual("consumed\n", result.stdout)

    def test_apply_marks_new_autostart_units_for_start(self):
        old_metadata = self.write_metadata(
            "new-unit-old.json",
            {
                "version": 5,
                "user": "alice",
                "identityStamp": "same",
                "managedUnits": [
                    {
                        "name": "old",
                        "unit": "old.service",
                        "autoStart": True,
                        "state": "running",
                        "stamp": "old",
                    },
                ],
            },
        )
        new_metadata = self.write_metadata(
            "new-unit-new.json",
            {
                "version": 5,
                "user": "alice",
                "identityStamp": "same",
                "managedUnits": [
                    {
                        "name": "old",
                        "unit": "old.service",
                        "autoStart": True,
                        "state": "running",
                        "stamp": "old",
                    },
                    {
                        "name": "new-running",
                        "unit": "new-running.service",
                        "autoStart": True,
                        "state": "running",
                        "stamp": "new-running",
                    },
                    {
                        "name": "new-stopped",
                        "unit": "new-stopped.service",
                        "autoStart": True,
                        "state": "stopped",
                        "stamp": "new-stopped",
                    },
                    {
                        "name": "new-manual",
                        "unit": "new-manual.service",
                        "autoStart": False,
                        "state": "running",
                        "stamp": "new-manual",
                    },
                ],
            },
        )

        result = self.run_helper(
            f"""
            init_managed_user alice
            old_tsv="$(read_metadata_stop_state_tsv {old_metadata})"
            new_tsv="$(read_metadata_stop_state_tsv {new_metadata})"
            diff_and_stop_units preview alice "$old_tsv" "$new_tsv"
            diff_and_stop_units apply alice "$old_tsv" "$new_tsv"
            consume_deferred_managed_unit_restart alice new-running
            consume_deferred_managed_unit_restart alice old
            consume_deferred_managed_unit_restart alice new-stopped
            consume_deferred_managed_unit_restart alice new-manual
            """
        )

        self.assertEqual(["consumed", "absent", "absent", "absent"], result.stdout.splitlines())
        self.assertIn("new-running: would start", result.stderr)
        self.assertNotIn("new-stopped: would start", result.stderr)
        self.assertNotIn("new-manual: would start", result.stderr)

    def test_metadata_rows_and_migration_manager_gate_override_reconcile_state(self):
        metadata = self.write_metadata(
            "metadata.json",
            {
                "version": 5,
                "user": "alice",
                "identityStamp": "identity-a",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 33,
                        "reloadStamp": "reload-a",
                        "repairCommand": ["/bin/echo", "repair"],
                        "verifyCommand": ["/bin/true"],
                    },
                    {
                        "name": "job",
                        "unit": "job.service",
                        "autoStart": False,
                        "state": "stopped",
                    },
                    {
                        "name": "legacy",
                        "unit": "legacy.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutStableSeconds": 44,
                    },
                ],
            },
        )
        gate = self.state_dir / "migration-gate"
        gate.touch()

        result = self.run_helper(
            f"""
            SYSTEMD_USER_MANAGER_METADATA={metadata}
            normal="$(read_metadata_reconcile_units_tsv "$SYSTEMD_USER_MANAGER_METADATA" | tr "$metadata_field_sep" '\\t')"
            migration_manager_gate_path={gate}
            gated="$(read_metadata_reconcile_units_tsv "$SYSTEMD_USER_MANAGER_METADATA" | tr "$metadata_field_sep" '\\t')"
            printf '%s\\n---\\n%s\\n' "$normal" "$gated"
            """
        )

        normal, gated = result.stdout.strip().split("\n---\n")
        self.assertIn("web\tweb.service\t1\trunning\t33\treload-a\t", normal)
        self.assertIn(base64.b64encode(b'["/bin/echo","repair"]').decode(), normal)
        self.assertIn("job\tjob.service\t0\tstopped\t120\t\t", normal)
        self.assertIn("legacy\tlegacy.service\t1\trunning\t44\t\t", normal)
        self.assertIn("web\tweb.service\t0\tstopped\t33\treload-a\t", gated)
        self.assertIn("job\tjob.service\t0\tstopped\t120\t\t", gated)
        self.assertIn("legacy\tlegacy.service\t0\tstopped\t44\t\t", gated)

    def test_deferred_restart_and_reload_markers_are_sanitized_and_consumable(self):
        result = self.run_helper(
            """
            mark_deferred_user_manager_restart 'tenant/alice'
            if consume_deferred_user_manager_restart 'tenant/alice'; then
              printf 'consumed\n'
            else
              printf 'absent\n'
            fi
            if consume_deferred_user_manager_restart 'tenant/alice'; then
              printf 'consumed\n'
            else
              printf 'absent\n'
            fi

            mark_deferred_managed_unit_restart 'tenant/alice' 'web/api'
            consume_deferred_managed_unit_restart 'tenant/alice' 'web/api'
            consume_deferred_managed_unit_restart 'tenant/alice' 'web/api'

            mark_deferred_managed_unit_reload 'tenant/alice' 'web/api' stamp-a
            consume_deferred_managed_unit_reload 'tenant/alice' 'web/api' stamp-b
            mark_deferred_managed_unit_reload 'tenant/alice' 'web/api' stamp-a
            consume_deferred_managed_unit_reload 'tenant/alice' 'web/api' stamp-a
            """
        )

        self.assertEqual(["consumed", "absent", "consumed", "absent", "stale", "consumed"], result.stdout.splitlines())
        self.assertFalse((self.state_dir / "manager-restarts/tenant-alice").exists())
        self.assertFalse((self.state_dir / "unit-restarts/tenant-alice/web-api").exists())
        self.assertFalse((self.state_dir / "unit-reloads/tenant-alice/web-api").exists())

    def test_metadata_pointer_lookup_and_applied_metadata_storage(self):
        alice = self.write_metadata("alice.json", {"version": 5, "user": "alice", "managedUnits": []})
        bob = self.write_metadata("bob.json", {"version": 5, "user": "bob", "managedUnits": []})
        system = self.work_dir / "system"
        pointer_dir = system / "etc/systemd-user-manager/dispatchers"
        pointer_dir.mkdir(parents=True)
        (pointer_dir / "alice.metadata").write_text(f"{alice}\n", encoding="utf-8")
        (pointer_dir / "bob.metadata").write_text(f"{bob}\n", encoding="utf-8")
        (pointer_dir / "empty.metadata").write_text("\n", encoding="utf-8")

        result = self.run_helper(
            f"""
            metadata_for_user_in_system bob {system}
            is_valid_metadata_file {alice} && printf 'valid\\n'
            store_applied_metadata 'tenant/alice' {alice}
            applied_metadata_path 'tenant/alice'
            """
        )

        bob_path, valid, applied_path = result.stdout.splitlines()
        self.assertEqual(str(bob), bob_path)
        self.assertEqual("valid", valid)
        self.assertEqual(str(self.state_dir / "applied/tenant-alice.json"), applied_path)
        self.assertEqual(json.loads(alice.read_text()), json.loads(Path(applied_path).read_text()))

    def test_diff_preview_reports_stops_reloads_removals_and_identity_restart(self):
        old_metadata = self.write_metadata(
            "old.json",
            {
                "version": 5,
                "user": "alice",
                "identityStamp": "old-identity",
                "managedUnits": [
                    {
                        "name": "restart",
                        "unit": "restart.service",
                        "stamp": "old",
                        "reloadStamp": "same",
                        "transitionNeutralStamp": "neutral",
                        "stopOnTransitionFrom": "restart-to-recreate",
                    },
                    {
                        "name": "reload",
                        "unit": "reload.service",
                        "stamp": "same",
                        "reloadStamp": "old-reload",
                    },
                    {
                        "name": "removed",
                        "unit": "removed.service",
                        "stamp": "removed",
                        "removalPolicy": "stop",
                    },
                ],
            },
        )
        new_metadata = self.write_metadata(
            "new.json",
            {
                "version": 5,
                "user": "alice",
                "identityStamp": "new-identity",
                "managedUnits": [
                    {
                        "name": "restart",
                        "unit": "restart.service",
                        "stamp": "new",
                        "reloadStamp": "same",
                        "transitionNeutralStamp": "neutral",
                        "stopOnTransitionTo": "restart-to-recreate",
                    },
                    {
                        "name": "reload",
                        "unit": "reload.service",
                        "stamp": "same",
                        "reloadStamp": "new-reload",
                    },
                ],
            },
        )

        result = self.run_helper(
            f"""
            old_tsv="$(read_metadata_stop_state_tsv {old_metadata})"
            new_tsv="$(read_metadata_stop_state_tsv {new_metadata})"
            diff_and_stop_units preview alice "$old_tsv" "$new_tsv"
            """,
            check=True,
        )

        self.assertIn("restart: would stop", result.stderr)
        self.assertIn("reload: would reload", result.stderr)
        self.assertIn("removed: would stop", result.stderr)
        self.assertIn("would restart user manager", result.stderr)

    def test_verification_failure_restarts_and_succeeds_on_second_verify(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        verify_count = self.state_dir / "verify-count"
        self._write_executable(
            self.fake_bin / "verify-web",
            f"""#!/bin/sh
count_file={shlex.quote(str(verify_count))}
count="$(cat "$count_file" 2>/dev/null || printf '%s\\n' 0)"
count="$((count + 1))"
printf '%s\\n' "$count" > "$count_file"
[ "$count" -gt 1 ]
""",
        )
        metadata = self.write_metadata(
            "verify.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                        "verifyCommand": ["verify-web"],
                    },
                ],
            },
        )

        result = self.run_helper(
            "verify_managed_units_from_metadata",
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
        )

        self.assertEqual("", result.stdout)
        self.assertEqual("2\n", verify_count.read_text(encoding="utf-8"))
        self.assertIn("web: verification failed; restarting", result.stderr)
        self.assertIn("web: verified after restart", result.stderr)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user --no-block restart web.service", systemctl_log)

    def test_reconciler_verifies_unchanged_active_unit(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        verify_count = self.state_dir / "verify-active-count"
        self._write_executable(
            self.fake_bin / "verify-web",
            f"""#!/bin/sh
count_file={shlex.quote(str(verify_count))}
count="$(cat "$count_file" 2>/dev/null || printf '%s\\n' 0)"
count="$((count + 1))"
printf '%s\\n' "$count" > "$count_file"
[ "$count" -gt 1 ]
""",
        )
        metadata = self.write_metadata(
            "active-stale-verify.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                        "verifyCommand": ["verify-web"],
                    },
                ],
            },
        )

        result = self.run_helper(
            "run_reconciler_apply",
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
        )

        self.assertEqual("2\n", verify_count.read_text(encoding="utf-8"))
        self.assertIn("web: verification failed; restarting", result.stderr)
        self.assertIn("web: verified after restart", result.stderr)
        self.assertIn("reconcile noop", result.stderr)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user --no-block restart web.service", systemctl_log)

    def test_enqueue_verification_failure_dispatches_repair_without_reverify(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        verify_count = self.state_dir / "verify-enqueue-count"
        self._write_executable(
            self.fake_bin / "verify-web",
            f"""#!/bin/sh
count_file={shlex.quote(str(verify_count))}
count="$(cat "$count_file" 2>/dev/null || printf '%s\\n' 0)"
count="$((count + 1))"
printf '%s\\n' "$count" > "$count_file"
exit 1
""",
        )
        metadata = self.write_metadata(
            "active-stale-verify-enqueue.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                        "startMode": "enqueue",
                        "verifyCommand": ["verify-web"],
                    },
                ],
            },
        )

        result = self.run_helper(
            "run_reconciler_apply",
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
        )

        self.assertEqual("1\n", verify_count.read_text(encoding="utf-8"))
        self.assertIn("web: verification failed; enqueueing restart", result.stderr)
        self.assertIn("web: restart enqueued after verification failure", result.stderr)
        self.assertNotIn("verified after restart", result.stderr)
        self.assertIn("reconcile noop", result.stderr)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user --no-block restart web.service", systemctl_log)

    def test_enqueue_verification_failure_uses_repair_command(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        verify_count = self.state_dir / "verify-repair-count"
        repair_log = self.state_dir / "repair.log"
        self._write_executable(
            self.fake_bin / "verify-web",
            f"""#!/bin/sh
count_file={shlex.quote(str(verify_count))}
count="$(cat "$count_file" 2>/dev/null || printf '%s\\n' 0)"
count="$((count + 1))"
printf '%s\\n' "$count" > "$count_file"
exit 1
""",
        )
        self._write_executable(
            self.fake_bin / "repair-web",
            f"#!/bin/sh\nprintf 'repair\\n' >> {shlex.quote(str(repair_log))}\n",
        )
        metadata = self.write_metadata(
            "active-stale-verify-repair.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                        "startMode": "enqueue",
                        "repairCommand": ["repair-web"],
                        "verifyCommand": ["verify-web"],
                    },
                ],
            },
        )

        result = self.run_helper(
            "run_reconciler_apply",
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
        )

        self.assertEqual("1\n", verify_count.read_text(encoding="utf-8"))
        self.assertEqual("repair\n", repair_log.read_text(encoding="utf-8"))
        self.assertIn("web: verification failed; enqueueing repair", result.stderr)
        self.assertIn("web: repair enqueued after verification failure", result.stderr)
        self.assertIn("reconcile noop", result.stderr)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertNotIn("--user --no-block restart web.service", systemctl_log)

    def test_enqueue_start_verification_failure_is_repaired_once_in_final_pass(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("inactive\n", encoding="utf-8")
        verify_count = self.state_dir / "verify-enqueue-start-count"
        self._write_executable(
            self.fake_bin / "verify-web",
            f"""#!/bin/sh
count_file={shlex.quote(str(verify_count))}
count="$(cat "$count_file" 2>/dev/null || printf '%s\\n' 0)"
count="$((count + 1))"
printf '%s\\n' "$count" > "$count_file"
exit 1
""",
        )
        metadata = self.write_metadata(
            "start-stale-verify-enqueue.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                        "startMode": "enqueue",
                        "verifyCommand": ["verify-web"],
                    },
                ],
            },
        )

        result = self.run_helper(
            "run_reconciler_apply",
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            FAKE_SYSTEMCTL_START_STATE="active",
        )

        self.assertEqual("1\n", verify_count.read_text(encoding="utf-8"))
        self.assertIn("web: verification failed; enqueueing restart", result.stderr)
        self.assertIn("web: restart enqueued after verification failure", result.stderr)
        self.assertIn("reconcile done", result.stderr)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user --no-block start web.service", systemctl_log)
        self.assertIn("--user --no-block restart web.service", systemctl_log)

    def test_enqueue_verification_does_not_wait_for_transitional_unit(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("deactivating\n", encoding="utf-8")
        verify_log = self.state_dir / "verify-web.log"
        self._write_executable(
            self.fake_bin / "verify-web",
            f"#!/bin/sh\nprintf 'verify\\n' >> {shlex.quote(str(verify_log))}\n",
        )
        metadata = self.write_metadata(
            "verify-enqueue-transitional.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 1,
                        "startMode": "enqueue",
                        "verifyCommand": ["verify-web"],
                    },
                ],
            },
        )

        result = self.run_helper(
            "verify_managed_units_from_metadata",
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
        )

        self.assertEqual("verify\n", verify_log.read_text(encoding="utf-8"))
        self.assertIn("web: verification deferred (state=deactivating)", result.stderr)
        self.assertNotIn("timed out waiting", result.stderr)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertNotIn("--user --no-block restart web.service", systemctl_log)

    def test_reconciler_recovers_deactivating_unit_without_restart_marker(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("deactivating\n", encoding="utf-8")
        metadata = self.write_metadata(
            "transient-no-marker.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 1,
                    },
                ],
            },
        )

        result = self.run_helper(
            "run_reconciler_apply",
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            FAKE_SYSTEMCTL_START_STATE="active",
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("web: recovering transitional state (state=deactivating)", result.stderr)
        self.assertIn("web: stopping", result.stderr)
        self.assertIn("web: started in", result.stderr)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user --no-block stop web.service", systemctl_log)
        self.assertIn("--user --no-block start web.service", systemctl_log)
        self.assertNotIn("--user --no-block restart web.service", systemctl_log)

    def test_reconciler_enqueues_deactivating_unit_recovery(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("deactivating\n", encoding="utf-8")
        metadata = self.write_metadata(
            "transient-enqueue-no-marker.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 1,
                        "startMode": "enqueue",
                    },
                ],
            },
        )

        result = self.run_helper(
            "run_reconciler_apply",
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            FAKE_SYSTEMCTL_START_STATE="active",
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("web: recovering transitional state (state=deactivating)", result.stderr)
        self.assertIn("web: started in", result.stderr)
        self.assertNotIn("web: stopping", result.stderr)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertNotIn("--user --no-block stop web.service", systemctl_log)
        self.assertIn("--user kill --kill-whom=all --signal=KILL web.service", systemctl_log)
        self.assertIn("--user --no-block start web.service", systemctl_log)
        self.assertNotIn("--user --no-block restart web.service", systemctl_log)

    def test_reconciler_joins_activating_unit_without_restart_marker(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        (self.state_dir / "systemctl-state").mkdir(parents=True)
        (self.state_dir / "systemctl-state/active-sequence").write_text(
            "activating\n"
            "active\n",
            encoding="utf-8",
        )
        metadata = self.write_metadata(
            "transient-settles-active.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            "run_reconciler_apply",
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            FAKE_SYSTEMCTL_START_STATE="active",
        )

        self.assertNotIn("web: recovering transitional state", result.stderr)
        self.assertIn("web: started in", result.stderr)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertNotIn("--user --no-block stop web.service", systemctl_log)
        self.assertIn("--user --no-block start web.service", systemctl_log)
        self.assertNotIn("--user --no-block restart web.service", systemctl_log)

    def test_reconciler_starts_failed_autostart_unit_without_restart_marker(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("failed\n", encoding="utf-8")
        metadata = self.write_metadata(
            "failed-no-marker.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            "run_reconciler_apply",
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            FAKE_SYSTEMCTL_START_STATE="active",
        )

        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user reset-failed web.service", systemctl_log)
        self.assertIn("--user --no-block start web.service", systemctl_log)
        self.assertIn("web: started in", result.stderr)
        self.assertIn("reconcile done", result.stderr)

    def test_reconciler_verifies_marker_restarted_unit(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        verify_count = self.state_dir / "verify-restarted-count"
        self._write_executable(
            self.fake_bin / "verify-web",
            f"""#!/bin/sh
count_file={shlex.quote(str(verify_count))}
count="$(cat "$count_file" 2>/dev/null || printf '%s\\n' 0)"
count="$((count + 1))"
printf '%s\\n' "$count" > "$count_file"
exit 0
""",
        )
        metadata = self.write_metadata(
            "active-marker-restart-verify.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                        "verifyCommand": ["verify-web"],
                    },
                ],
            },
        )

        result = self.run_helper(
            f"""
            mark_deferred_managed_unit_restart alice web
            run_reconciler_apply
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
        )

        self.assertEqual("1\n", verify_count.read_text(encoding="utf-8"))
        self.assertIn("web: restarted in", result.stderr)
        self.assertIn("reconcile done", result.stderr)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user --no-block restart web.service", systemctl_log)

    def test_reconciler_active_restart_marker_uses_repair_command(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        repair_log = self.state_dir / "marker-repair.log"
        self._write_executable(
            self.fake_bin / "repair-web",
            f"#!/bin/sh\nprintf 'repair\\n' >> {shlex.quote(str(repair_log))}\n",
        )
        metadata = self.write_metadata(
            "active-marker-repair.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                        "startMode": "enqueue",
                        "repairCommand": ["repair-web"],
                    },
                ],
            },
        )

        result = self.run_helper(
            f"""
            mark_deferred_managed_unit_restart alice web
            run_reconciler_apply
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
        )

        self.assertEqual("repair\n", repair_log.read_text(encoding="utf-8"))
        self.assertIn("web: enqueueing repair", result.stderr)
        self.assertIn("web: repair enqueued", result.stderr)
        self.assertIn("reconcile done", result.stderr)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertNotIn("--user --no-block restart web.service", systemctl_log)

    def test_reconciler_recovers_transitional_unit_with_restart_marker(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("activating\n", encoding="utf-8")
        metadata = self.write_metadata(
            "transitional-marker-restart.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            """
            mark_deferred_managed_unit_restart alice web
            run_reconciler_apply
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            FAKE_SYSTEMCTL_START_STATE="active",
        )

        self.assertIn("web: recovering transitional state (state=activating)", result.stderr)
        self.assertIn("web: started in", result.stderr)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user --no-block stop web.service", systemctl_log)
        self.assertIn("--user --no-block start web.service", systemctl_log)
        self.assertNotIn("--user --no-block restart web.service", systemctl_log)

    def test_unit_stable_state_waits_through_repeated_transitional_restarts(self):
        self.write_fake_setpriv()
        log_path = shlex.quote(str(self.state_dir / "systemctl.log"))
        restarts_path = shlex.quote(str(self.state_dir / "restarts"))
        active_calls_path = shlex.quote(str(self.state_dir / "active-calls"))
        self._write_executable(
            self.fake_bin / "systemctl",
            f"""#!/bin/sh
set -eu
printf '%s\\n' "$*" >> {log_path}
if [ "${{1-}}" = "--user" ]; then
  shift
fi
case "${{1-}}" in
  show)
    property=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --property=*) property="${{1#--property=}}" ;;
      esac
      shift
    done
    case "$property" in
      ActiveState)
        calls="$(cat {active_calls_path} 2>/dev/null || printf '%s\\n' 0)"
        calls="$((calls + 1))"
        printf '%s\\n' "$calls" > {active_calls_path}
        if [ "$calls" -lt 5 ]; then
          printf '%s\\n' "activating"
        else
          printf '%s\\n' "active"
        fi
        ;;
      SubState) printf '%s\\n' "start" ;;
      Result) printf '%s\\n' "success" ;;
      NRestarts)
        count="$(cat {restarts_path} 2>/dev/null || printf '%s\\n' 0)"
        next="$((count + 1))"
        printf '%s\\n' "$next" > {restarts_path}
        printf '%s\\n' "$count"
        ;;
      *) printf '%s\\n' "" ;;
    esac
    ;;
esac
""",
        )

        result = self.run_helper("unit_stable_state web.service 30", SYSTEMD_USER_MANAGER_USER="alice")

        self.assertEqual("active\n", result.stdout)
        self.assertIn("restarted while converging", result.stderr)
        self.assertIn("restarts=", result.stderr)

    def test_unit_stable_state_accepts_active_state_after_transient_restart(self):
        self.write_fake_setpriv()
        log_path = shlex.quote(str(self.state_dir / "systemctl.log"))
        active_calls_path = shlex.quote(str(self.state_dir / "active-calls"))
        restart_calls_path = shlex.quote(str(self.state_dir / "restart-calls"))
        self._write_executable(
            self.fake_bin / "systemctl",
            f"""#!/bin/sh
set -eu
printf '%s\\n' "$*" >> {log_path}
if [ "${{1-}}" = "--user" ]; then
  shift
fi
case "${{1-}}" in
  show)
    property=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --property=*) property="${{1#--property=}}" ;;
      esac
      shift
    done
    case "$property" in
      ActiveState)
        calls="$(cat {active_calls_path} 2>/dev/null || printf '%s\\n' 0)"
        calls="$((calls + 1))"
        printf '%s\\n' "$calls" > {active_calls_path}
        if [ "$calls" -lt 3 ]; then
          printf '%s\\n' "activating"
        else
          printf '%s\\n' "active"
        fi
        ;;
      SubState) printf '%s\\n' "start" ;;
      Result) printf '%s\\n' "success" ;;
      NRestarts)
        restart_calls="$(cat {restart_calls_path} 2>/dev/null || printf '%s\\n' 0)"
        restart_calls="$((restart_calls + 1))"
        printf '%s\\n' "$restart_calls" > {restart_calls_path}
        if [ "$restart_calls" -eq 1 ]; then
          printf '%s\\n' "0"
        else
          printf '%s\\n' "1"
        fi
        ;;
      *) printf '%s\\n' "" ;;
    esac
    ;;
esac
""",
        )

        result = self.run_helper(
            "unit_stable_state web.service 30",
            SYSTEMD_USER_MANAGER_USER="alice",
        )

        self.assertEqual("active\n", result.stdout)
        self.assertIn("restarted while converging", result.stderr)
        self.assertIn("stable state reached", result.stderr)

    def test_reconciler_start_resets_stale_failed_state_before_no_block_start(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("failed\n", encoding="utf-8")
        metadata = self.write_metadata(
            "start-failed.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            """
            mark_deferred_managed_unit_restart alice web
            run_reconciler_apply
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            FAKE_SYSTEMCTL_START_STATE="active",
        )

        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user kill --kill-whom=all --signal=TERM web.service", systemctl_log)
        self.assertIn("--user reset-failed web.service", systemctl_log)
        self.assertIn("--user --no-block start web.service", systemctl_log)
        self.assertIn("web: started in", result.stderr)
        self.assertIn("reconcile done", result.stderr)

    def test_reconciler_launches_managed_unit_starts_before_waiting(self):
        self.write_fake_setpriv()
        log_path = shlex.quote(str(self.state_dir / "systemctl.log"))
        alpha_done_path = shlex.quote(str(self.state_dir / "alpha.done"))
        beta_before_alpha_path = shlex.quote(str(self.state_dir / "beta-before-alpha"))
        started_dir = shlex.quote(str(self.state_dir / "started"))
        self._write_executable(
            self.fake_bin / "systemctl",
            f"""#!/bin/sh
set -eu
mkdir -p {started_dir}
printf '%s\\n' "$*" >> {log_path}
if [ "${{1-}}" = "is-active" ]; then
  exit 0
fi
if [ "${{1-}}" = "--user" ]; then
  shift
fi
if [ "${{1-}}" = "--no-block" ]; then
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
        if [ -f "{started_dir}/$unit" ]; then
          printf '%s\\n' "active"
        else
          printf '%s\\n' "inactive"
        fi
        ;;
      LoadState) printf '%s\\n' "loaded" ;;
      SubState) printf '%s\\n' "dead" ;;
      Result) printf '%s\\n' "success" ;;
      Type) printf '%s\\n' "simple" ;;
      NRestarts) printf '%s\\n' "0" ;;
      UnitFileState) printf '%s\\n' "enabled" ;;
      InvocationID) printf '%s\\n' "fake-invocation" ;;
      Job) printf '%s\\n' "" ;;
      *) printf '%s\\n' "" ;;
    esac
    ;;
  start)
    if [ "$1" = alpha.service ]; then
      sleep 1
      touch {alpha_done_path}
    elif [ "$1" = beta.service ] && [ ! -f {alpha_done_path} ]; then
      touch {beta_before_alpha_path}
    fi
    touch "{started_dir}/$1"
    ;;
  daemon-reload|reset-failed|kill)
    ;;
esac
""",
        )
        metadata = self.write_metadata(
            "sequential-start.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "alpha",
                        "unit": "alpha.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                    {
                        "name": "beta",
                        "unit": "beta.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            """
            mark_deferred_managed_unit_restart alice alpha
            mark_deferred_managed_unit_restart alice beta
            run_reconciler_apply
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            SYSTEMD_USER_MANAGER_START_CONCURRENCY="4",
        )

        self.assertIn("alpha: started in", result.stderr)
        self.assertIn("beta: started in", result.stderr)
        self.assertIn("reconcile done", result.stderr)
        self.assertTrue((self.state_dir / "beta-before-alpha").exists())

    def test_reconciler_bounds_concurrent_managed_unit_starts(self):
        self.write_fake_setpriv()
        log_path = shlex.quote(str(self.state_dir / "systemctl.log"))
        alpha_done_path = shlex.quote(str(self.state_dir / "alpha.done"))
        beta_before_alpha_path = shlex.quote(str(self.state_dir / "beta-before-alpha"))
        started_dir = shlex.quote(str(self.state_dir / "started"))
        self._write_executable(
            self.fake_bin / "systemctl",
            f"""#!/bin/sh
set -eu
mkdir -p {started_dir}
printf '%s\\n' "$*" >> {log_path}
if [ "${{1-}}" = "is-active" ]; then
  exit 0
fi
if [ "${{1-}}" = "--user" ]; then
  shift
fi
if [ "${{1-}}" = "--no-block" ]; then
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
        if [ -f "{started_dir}/$unit" ]; then
          printf '%s\\n' "active"
        else
          printf '%s\\n' "inactive"
        fi
        ;;
      LoadState) printf '%s\\n' "loaded" ;;
      SubState) printf '%s\\n' "dead" ;;
      Result) printf '%s\\n' "success" ;;
      Type) printf '%s\\n' "simple" ;;
      NRestarts) printf '%s\\n' "0" ;;
      UnitFileState) printf '%s\\n' "enabled" ;;
      InvocationID) printf '%s\\n' "fake-invocation" ;;
      Job) printf '%s\\n' "" ;;
      *) printf '%s\\n' "" ;;
    esac
    ;;
  start)
    if [ "$1" = alpha.service ]; then
      sleep 0.2
      touch {alpha_done_path}
    elif [ "$1" = beta.service ] && [ ! -f {alpha_done_path} ]; then
      touch {beta_before_alpha_path}
    fi
    touch "{started_dir}/$1"
    ;;
  daemon-reload|reset-failed|kill)
    ;;
esac
""",
        )
        metadata = self.write_metadata(
            "bounded-start.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "alpha",
                        "unit": "alpha.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                    {
                        "name": "beta",
                        "unit": "beta.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            """
            mark_deferred_managed_unit_restart alice alpha
            mark_deferred_managed_unit_restart alice beta
            run_reconciler_apply
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            SYSTEMD_USER_MANAGER_START_CONCURRENCY="1",
        )

        self.assertIn("alpha: started in", result.stderr)
        self.assertIn("beta: started in", result.stderr)
        self.assertIn("reconcile done", result.stderr)
        self.assertFalse((self.state_dir / "beta-before-alpha").exists())

    def test_reconciler_start_still_fails_when_new_start_reaches_failed_state(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        self._write_executable(
            self.fake_bin / "journalctl",
            "#!/bin/sh\nprintf '%s\\n' 'Stalwart recovery apply failed'\n",
        )
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("inactive\n", encoding="utf-8")
        metadata = self.write_metadata(
            "start-failed.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            """
            mark_deferred_managed_unit_restart alice web
            run_reconciler_apply
            """,
            check=False,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            FAKE_SYSTEMCTL_START_STATE="failed",
            FAKE_SYSTEMCTL_RESULT="exit-code",
            FAKE_SYSTEMCTL_EXEC_MAIN_STATUS="1",
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("unit web.service reached stable non-active state after start: failed", result.stderr)
        self.assertIn("web: failed to start after", result.stderr)
        self.assertIn(
            "managed unit failure: unit=web.service ActiveState=failed "
            "SubState=dead Result=exit-code ExecMainCode=exited ExecMainStatus=1",
            result.stderr,
        )
        self.assertIn("Stalwart recovery apply failed", result.stderr)
        self.assertIn("failed managed units: web", result.stderr)

    def test_reconciler_starts_inactive_autostart_unit_without_marker(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("inactive\n", encoding="utf-8")
        metadata = self.write_metadata(
            "start-inactive-no-marker.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            """
            run_reconciler_apply
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            FAKE_SYSTEMCTL_START_STATE="active",
        )

        self.assertIn("web: started in", result.stderr)
        self.assertIn("--no-block start web.service", (self.state_dir / "systemctl.log").read_text())

    def test_reconciler_start_accepts_active_state_after_no_block_failure(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("inactive\n", encoding="utf-8")
        metadata = self.write_metadata(
            "start-active-after-error.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            """
            mark_deferred_managed_unit_restart alice web
            run_reconciler_apply
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            FAKE_SYSTEMCTL_START_FAIL="1",
            FAKE_SYSTEMCTL_START_STATE="active",
        )

        self.assertIn("web: started in", result.stderr)
        self.assertIn("reconcile done", result.stderr)
        self.assertIn("--no-block start web.service", (self.state_dir / "systemctl.log").read_text())

    def test_reconciler_start_waits_for_no_block_start_to_materialize(self):
        self.write_fake_setpriv()
        log_path = shlex.quote(str(self.state_dir / "systemctl.log"))
        active_calls_path = shlex.quote(str(self.state_dir / "active-calls"))
        start_called_path = shlex.quote(str(self.state_dir / "start-called"))
        self._write_executable(
            self.fake_bin / "systemctl",
            f"""#!/bin/sh
set -eu
printf '%s\\n' "$*" >> {log_path}
if [ "${{1-}}" = "is-active" ]; then
  exit 0
fi
if [ "${{1-}}" = "--user" ]; then
  shift
fi
if [ "${{1-}}" = "--no-block" ]; then
  shift
fi
cmd="${{1-}}"
if [ "$#" -gt 0 ]; then
  shift
fi
case "$cmd" in
  show)
    property=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --property=*) property="${{1#--property=}}" ;;
      esac
      shift
    done
    case "$property" in
      ActiveState)
        if [ ! -f {start_called_path} ]; then
          printf '%s\\n' "inactive"
          exit 0
        fi
        calls="$(cat {active_calls_path} 2>/dev/null || printf '%s\\n' 0)"
        calls="$((calls + 1))"
        printf '%s\\n' "$calls" > {active_calls_path}
        if [ "$calls" -lt 3 ]; then
          printf '%s\\n' "inactive"
        else
          printf '%s\\n' "active"
        fi
        ;;
      LoadState) printf '%s\\n' "loaded" ;;
      SubState) printf '%s\\n' "dead" ;;
      Result) printf '%s\\n' "success" ;;
      Type) printf '%s\\n' "simple" ;;
      NRestarts) printf '%s\\n' "0" ;;
      UnitFileState) printf '%s\\n' "enabled" ;;
      *) printf '%s\\n' "" ;;
    esac
    ;;
  start)
    : > {start_called_path}
    ;;
esac
""",
        )
        metadata = self.write_metadata(
            "start-materialize.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            """
            mark_deferred_managed_unit_restart alice web
            run_reconciler_apply
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
        )

        active_calls = int((self.state_dir / "active-calls").read_text(encoding="utf-8"))
        self.assertGreaterEqual(active_calls, 3)
        self.assertIn("web: started in", result.stderr)
        self.assertIn("reconcile done", result.stderr)

    def test_reconciler_start_fails_when_service_remains_inactive(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("inactive\n", encoding="utf-8")
        metadata = self.write_metadata(
            "start-inactive.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            """
            mark_deferred_managed_unit_restart alice web
            run_reconciler_apply
            """,
            check=False,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            SYSTEMD_USER_MANAGER_START_MATERIALIZE_SECONDS="1",
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("unit web.service reached stable non-active state after start: inactive", result.stderr)
        self.assertIn("failed managed units: web", result.stderr)

    def test_reconciler_accepts_unit_that_converges_after_start_wait_timeout(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("inactive\n", encoding="utf-8")
        (self.state_dir / "systemctl-state/active-sequence").write_text(
            "inactive\n"
            "activating\n"
            "active\n",
            encoding="utf-8",
        )
        metadata = self.write_metadata(
            "start-delayed-convergence.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 0,
                    },
                ],
            },
        )

        result = self.run_helper(
            """
            run_reconciler_apply
            """,
            check=False,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
        )

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("web: failed to start after", result.stderr)
        self.assertIn("web: recovered after delayed convergence", result.stderr)
        self.assertIn("reconcile done", result.stderr)
        self.assertNotIn("failed managed units: web", result.stderr)

    def test_failed_unit_pruning_does_not_wait_for_a_second_timeout(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("activating\n", encoding="utf-8")
        metadata = self.write_metadata(
            "failed-prune.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 3,
                    },
                ],
            },
        )

        started_at = time.monotonic()
        result = self.run_helper(
            """
            managed_units_tsv="$(read_metadata_reconcile_units_tsv "$SYSTEMD_USER_MANAGER_METADATA")"
            prune_converged_failed_units " web" "$managed_units_tsv"
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
        )

        self.assertLess(time.monotonic() - started_at, 2)
        self.assertEqual("web", result.stdout.strip())

    def test_reconciler_start_waits_for_pending_start_job(self):
        self.write_fake_setpriv()
        log_path = shlex.quote(str(self.state_dir / "systemctl.log"))
        active_calls_path = shlex.quote(str(self.state_dir / "active-calls"))
        start_called_path = shlex.quote(str(self.state_dir / "start-called"))
        self._write_executable(
            self.fake_bin / "systemctl",
            f"""#!/bin/sh
set -eu
printf '%s\\n' "$*" >> {log_path}
if [ "${{1-}}" = "is-active" ]; then
  exit 0
fi
if [ "${{1-}}" = "--user" ]; then
  shift
fi
if [ "${{1-}}" = "--no-block" ]; then
  shift
fi
cmd="${{1-}}"
if [ "$#" -gt 0 ]; then
  shift
fi
case "$cmd" in
  show)
    property=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --property=*) property="${{1#--property=}}" ;;
      esac
      shift
    done
    calls="$(cat {active_calls_path} 2>/dev/null || printf '%s\\n' 0)"
    case "$property" in
      ActiveState)
        if [ ! -f {start_called_path} ]; then
          printf '%s\\n' "inactive"
          exit 0
        fi
        calls="$((calls + 1))"
        printf '%s\\n' "$calls" > {active_calls_path}
        if [ "$calls" -lt 4 ]; then
          printf '%s\\n' "inactive"
        else
          printf '%s\\n' "active"
        fi
        ;;
      Job)
        if [ -f {start_called_path} ] && [ "$calls" -lt 4 ]; then
          printf '%s\\n' "77"
        else
          printf '%s\\n' ""
        fi
        ;;
      LoadState) printf '%s\\n' "loaded" ;;
      SubState) printf '%s\\n' "dead" ;;
      Result) printf '%s\\n' "success" ;;
      Type) printf '%s\\n' "simple" ;;
      NRestarts) printf '%s\\n' "0" ;;
      UnitFileState) printf '%s\\n' "enabled" ;;
      *) printf '%s\\n' "" ;;
    esac
    ;;
  start)
    : > {start_called_path}
    ;;
esac
""",
        )
        metadata = self.write_metadata(
            "start-job.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            """
            mark_deferred_managed_unit_restart alice web
            run_reconciler_apply
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            SYSTEMD_USER_MANAGER_START_MATERIALIZE_SECONDS="1",
        )

        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--property=Job --value web.service", systemctl_log)
        self.assertIn("web: started in", result.stderr)
        self.assertIn("reconcile done", result.stderr)

    def test_reconciler_start_accepts_successful_oneshot_completion(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        state_file = self.state_dir / "systemctl-state/web.service.active"
        state_file.parent.mkdir(parents=True)
        state_file.write_text("inactive\n", encoding="utf-8")
        metadata = self.write_metadata(
            "start-oneshot.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            """
            mark_deferred_managed_unit_restart alice web
            run_reconciler_apply
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
            FAKE_SYSTEMCTL_SERVICE_TYPE="oneshot",
        )

        self.assertIn("web: started in", result.stderr)
        self.assertIn("reconcile done", result.stderr)

    def test_verification_failure_reports_second_verify_failure(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        verify_count = self.state_dir / "verify-fail-count"
        self._write_executable(
            self.fake_bin / "verify-web",
            f"""#!/bin/sh
count_file={shlex.quote(str(verify_count))}
count="$(cat "$count_file" 2>/dev/null || printf '%s\\n' 0)"
printf '%s\\n' "$((count + 1))" > "$count_file"
exit 1
""",
        )
        self._write_executable(
            self.fake_bin / "journalctl",
            "#!/bin/sh\nprintf '%s\\n' 'provider verification remained unhealthy'\n",
        )
        metadata = self.write_metadata(
            "verify-fail.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                        "verifyCommand": ["verify-web"],
                    },
                ],
            },
        )

        result = self.run_helper(
            "run_reconciler_apply",
            check=False,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
        )

        self.assertNotEqual(0, result.returncode)
        self.assertEqual("2\n", verify_count.read_text(encoding="utf-8"))
        self.assertIn("web: verification still failed after restart", result.stderr)
        self.assertIn("failed managed unit verification: web", result.stderr)
        self.assertIn("managed unit failure: unit=web.service", result.stderr)
        self.assertIn("provider verification remained unhealthy", result.stderr)
        self.assertIn("failed managed units: web", result.stderr)
        self.assertNotIn("failed managed units: verification", result.stderr)

    def test_malformed_applied_metadata_is_discarded_and_current_metadata_is_stopped(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        metadata = self.write_metadata(
            "current.json",
            {
                "version": 5,
                "user": "alice",
                "managedUnits": [
                    {
                        "name": "web",
                        "unit": "web.service",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )
        malformed_state = self.state_dir / "applied/alice.json"
        malformed_state.parent.mkdir(parents=True)
        malformed_state.write_text("{not-json", encoding="utf-8")

        result = self.run_helper(
            """
            init_managed_user_from_env
            userctl_mode=root
            stop_changed_managed_units_from_applied_metadata
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_UID="1001",
            SYSTEMD_USER_MANAGER_METADATA=str(metadata),
        )

        self.assertFalse(malformed_state.exists())
        self.assertIn("discarding malformed applied metadata", result.stderr)
        self.assertEqual(
            "web\n",
            (self.state_dir / "unit-restarts/alice/web").read_text(encoding="utf-8"),
        )
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user --no-block stop web.service", systemctl_log)

    def test_metadata_version_change_stops_only_removed_units(self):
        self.write_fake_setpriv()
        self.write_fake_systemctl()
        applied_metadata = {
            "version": 5,
            "user": "alice",
            "identityStamp": "same",
            "managedUnits": [
                {
                    "name": "kept",
                    "unit": "kept.service",
                    "removalPolicy": "stop",
                    "stamp": "old-kept",
                    "autoStart": True,
                    "state": "running",
                    "timeoutReadySeconds": 5,
                },
                {
                    "name": "removed",
                    "unit": "removed.service",
                    "removalPolicy": "stop",
                    "stamp": "old-removed",
                    "autoStart": True,
                    "state": "running",
                    "timeoutReadySeconds": 5,
                },
            ],
        }
        applied_state = self.state_dir / "applied/alice.json"
        applied_state.parent.mkdir(parents=True)
        applied_state.write_text(json.dumps(applied_metadata), encoding="utf-8")
        current_metadata = self.write_metadata(
            "current-version.json",
            {
                "version": 6,
                "user": "alice",
                "identityStamp": "same",
                "managedUnits": [
                    {
                        "name": "kept",
                        "unit": "kept.service",
                        "removalPolicy": "stop",
                        "stamp": "new-kept",
                        "autoStart": True,
                        "state": "running",
                        "timeoutReadySeconds": 5,
                    },
                ],
            },
        )

        result = self.run_helper(
            """
            init_managed_user_from_env
            userctl_mode=root
            stop_changed_managed_units_from_applied_metadata
            """,
            SYSTEMD_USER_MANAGER_USER="alice",
            SYSTEMD_USER_MANAGER_UID="1001",
            SYSTEMD_USER_MANAGER_METADATA=str(current_metadata),
        )

        self.assertIn("applied metadata version changed; stopping removed units only", result.stderr)
        self.assertFalse((self.state_dir / "unit-restarts/alice/kept").exists())
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user --no-block stop removed.service", systemctl_log)
        self.assertNotIn("--user --no-block stop kept.service", systemctl_log)

    def test_stopped_state_wait_tolerates_queued_stop_gap(self):
        self.write_fake_systemctl()
        sequence = self.state_dir / "systemctl-state/active-sequence"
        sequence.parent.mkdir(parents=True)
        sequence.write_text("active\ninactive\n", encoding="utf-8")

        result = self.run_helper(
            """
            userctl_mode=user
            wait_for_unit_stopped_state web.service 3
            """,
        )

        self.assertEqual("inactive\n", result.stdout)

    def test_stop_timeout_kills_residual_processes_and_rechecks(self):
        self.write_fake_systemctl()

        result = self.run_helper(
            """
            apply_stop_phase_action apply alice web web.service 1 0
            """,
            FAKE_SYSTEMCTL_STOP_STATE="active",
            FAKE_SYSTEMCTL_KILL_STATE="inactive",
            SYSTEMD_USER_MANAGER_STOP_KILL_WAIT_SECONDS="3",
        )

        self.assertIn(
            "web: stop wait exceeded after",
            result.stderr,
        )
        self.assertIn("web: stopped in", result.stderr)
        systemctl_log = (self.state_dir / "systemctl.log").read_text(encoding="utf-8")
        self.assertIn("--user kill --kill-whom=all --signal=KILL web.service", systemctl_log)

    def test_stop_wait_uses_stop_cleanup_budget_not_stable_timeout(self):
        self.write_fake_systemctl()
        date_counter = self.state_dir / "date-counter"
        date_counter.write_text("0\n", encoding="utf-8")
        self._write_executable(
            self.fake_bin / "date",
            f"""#!/bin/sh
set -eu
if [ "${{1-}}" = "+%s" ]; then
  count="$(cat {shlex.quote(str(date_counter))})"
  count="$((count + 3))"
  printf '%s\\n' "$count" > {shlex.quote(str(date_counter))}
  printf '%s\\n' "$count"
  exit 0
fi
exec /run/current-system/sw/bin/date "$@"
""",
        )

        result = self.run_helper(
            """
            sleep() { :; }
            apply_stop_phase_action apply alice web web.service 99 0
            """,
            FAKE_SYSTEMCTL_STOP_STATE="active",
            FAKE_SYSTEMCTL_KILL_STATE="inactive",
            SYSTEMD_USER_MANAGER_STOP_KILL_WAIT_SECONDS="3",
        )

        self.assertIn(
            "timed out waiting 3s for stopped state for web.service",
            result.stderr,
        )
        self.assertNotIn("timed out waiting 99s", result.stderr)


if __name__ == "__main__":
    unittest.main()
