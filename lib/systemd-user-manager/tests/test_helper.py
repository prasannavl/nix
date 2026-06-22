import base64
import json
import os
import shutil
import subprocess
import tempfile
import textwrap
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

    def encoded_command(self, command):
        return base64.b64encode(json.dumps(command).encode()).decode()

    def test_metadata_rows_and_migrator_gate_override_reconcile_state(self):
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
                        "timeoutStableSeconds": 33,
                        "reloadStamp": "reload-a",
                        "verifyCommand": ["/bin/true"],
                    },
                    {
                        "name": "job",
                        "unit": "job.service",
                        "autoStart": False,
                        "state": "stopped",
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
            migrator_gate_path={gate}
            gated="$(read_metadata_reconcile_units_tsv "$SYSTEMD_USER_MANAGER_METADATA" | tr "$metadata_field_sep" '\\t')"
            printf '%s\\n---\\n%s\\n' "$normal" "$gated"
            """
        )

        normal, gated = result.stdout.strip().split("\n---\n")
        self.assertIn("web\tweb.service\t1\trunning\t33\treload-a\t", normal)
        self.assertIn("job\tjob.service\t0\tstopped\t120\t\t", normal)
        self.assertIn("web\tweb.service\t0\tstopped\t33\treload-a\t", gated)
        self.assertIn("job\tjob.service\t0\tstopped\t120\t\t", gated)

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


if __name__ == "__main__":
    unittest.main()
