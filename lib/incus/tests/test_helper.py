import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class IncusHelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[3]
        cls.helper = cls.repo_root / "lib/incus/helper.sh"
        cls.fake_incus = cls.repo_root / "lib/incus/tests/fake_incus.py"
        cls.real_mktemp = shutil.which("mktemp") or "/usr/bin/mktemp"
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def setUp(self):
        self.work_dir = Path(tempfile.mkdtemp(prefix="incus-helper-test.", dir=self.tmp_root))
        self.fake_bin = self.work_dir / "bin"
        self.state_dir = self.work_dir / "state"
        self.fake_bin.mkdir()
        self.state_dir.mkdir()
        self.incus_log = self.work_dir / "incus.log"
        self.ip_log = self.work_dir / "ip.log"
        self.remote_config_dir = self.work_dir / "remote-config"
        self._write_executable(
            self.fake_bin / "incus",
            f"#!/bin/sh\nexec python3 {self.fake_incus} \"$@\"\n",
        )
        self._write_executable(
            self.fake_bin / "ip",
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"$TEST_IP_LOG\"\n",
        )
        self._write_executable(
            self.fake_bin / "mktemp",
            textwrap.dedent(
                f"""\
                #!/bin/sh
                if [ "${{1:-}}" = "-d" ] && [ "${{2:-}}" = "/run/incus-machines-client.XXXXXX" ]; then
                  rm -rf -- "$TEST_REMOTE_CONFIG_DIR"
                  mkdir -p "$TEST_REMOTE_CONFIG_DIR"
                  printf '%s\\n' "$TEST_REMOTE_CONFIG_DIR"
                  exit 0
                fi
                exec {self.real_mktemp} "$@"
                """
            ),
        )

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
                "TEST_INCUS_LOG": str(self.incus_log),
                "TEST_IP_LOG": str(self.ip_log),
                "TEST_REMOTE_CONFIG_DIR": str(self.remote_config_dir),
                "INCUS_MACHINES_HOST_SUSPEND_STATE_DIR": str(self.state_dir / "host-suspend"),
                "INCUS_MACHINES_MANAGED_GC_DIR_ROOT": str(self.state_dir / "managed-dirs"),
                "INCUS_MACHINES_ROUTES_STATE_FILE": str(self.state_dir / "routes.json"),
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

    def read_incus_log(self):
        if not self.incus_log.exists():
            return []
        return [json.loads(line) for line in self.incus_log.read_text(encoding="utf-8").splitlines()]

    def test_selection_resolves_ids_names_projects_and_refs(self):
        result = self.run_helper(
            """
            parse_machine_selection_args --machine vm --machine web
            printf '%s\n' "$selected_json"
            set_current_project_for_instance lab.vm
            printf '%s\n' "$current_project"
            instance_name_for_id lab.vm
            instance_state_for_id lab.vm
            instance_reconcile_policy_for_id ignored
            instance_ref vm
            query_ref '/1.0/instances/vm'
            """,
            INCUS_MACHINES_DECLARED_INSTANCES='["web","ignored","lab.vm"]',
            INCUS_MACHINES_INSTANCE_NAMES='{"lab.vm":"vm"}',
            INCUS_MACHINES_INSTANCE_PROJECTS='{"lab.vm":"lab"}',
            INCUS_MACHINES_INSTANCE_STATES='{"lab.vm":"stopped"}',
            INCUS_MACHINES_INSTANCE_RECONCILE_POLICIES='{"ignored":"ignore"}',
        )

        lines = result.stdout.splitlines()
        self.assertEqual(["lab.vm", "web"], json.loads(lines[0]))
        self.assertEqual("lab", lines[1])
        self.assertEqual("vm", lines[2])
        self.assertEqual("stopped", lines[3])
        self.assertEqual("ignore", lines[4])
        self.assertEqual("vm", lines[5])
        self.assertEqual("/1.0/instances/vm?project=lab", lines[6])

    def test_remote_setup_materializes_client_config_without_accepting_unknown_cert(self):
        client_cert = self.work_dir / "client.crt"
        client_key = self.work_dir / "client.key"
        server_cert = self.work_dir / "server.crt"
        client_cert.write_text("client cert\n", encoding="utf-8")
        client_key.write_text("client key\n", encoding="utf-8")
        server_cert.write_text("server cert\n", encoding="utf-8")

        result = self.run_helper(
            """
            setup_incus_client
            printf '%s\n' "$INCUS_CONF"
            stat -c '%a' "$INCUS_CONF/client.key"
            cat "$INCUS_CONF/config.yml"
            printf '%s\n' '---server-cert---'
            cat "$INCUS_CONF/servercerts/prod.crt"
            """,
            INCUS_MACHINES_REMOTE_NAME="prod",
            INCUS_MACHINES_REMOTE_ADDRESS="https://incus.example.test:8443",
            INCUS_MACHINES_REMOTE_PROJECT="tenant",
            INCUS_MACHINES_REMOTE_CLIENT_CERT_FILE=str(client_cert),
            INCUS_MACHINES_REMOTE_CLIENT_KEY_FILE=str(client_key),
            INCUS_MACHINES_REMOTE_SERVER_CERT_FILE=str(server_cert),
        )

        lines = result.stdout.splitlines()
        self.assertEqual(str(self.remote_config_dir), lines[0])
        self.assertEqual("600", lines[1])
        marker_index = lines.index("---server-cert---")
        config_text = "\n".join(lines[2:marker_index])
        self.assertIn("default-remote: prod", config_text)
        self.assertIn("addr: https://incus.example.test:8443", config_text)
        self.assertIn("project: tenant", config_text)
        self.assertEqual(["server cert"], lines[marker_index + 1 :])
        self.assertEqual([], self.read_incus_log())

    def test_routes_reconcile_removes_old_routes_applies_current_routes_and_persists_state(self):
        routes_file = self.work_dir / "routes.json"
        current_routes = [
            {
                "project": "default",
                "interface": "incusbr0",
                "address": "10.10.30.0",
                "prefixLength": 24,
                "via": "10.10.30.1",
            }
        ]
        old_routes = [
            {
                "project": "old",
                "interface": "incusbr0",
                "address": "10.10.20.0",
                "prefixLength": 24,
                "via": "10.10.20.1",
            }
        ]
        routes_file.write_text(json.dumps(current_routes), encoding="utf-8")
        (self.state_dir / "routes.json").write_text(json.dumps(old_routes), encoding="utf-8")

        self.run_helper("routes_main", INCUS_MACHINES_ROUTES_FILE=str(routes_file))

        ip_commands = self.ip_log.read_text(encoding="utf-8").splitlines()
        self.assertIn("-4 route del 10.10.20.0/24 via 10.10.20.1 dev incusbr0 proto static", ip_commands)
        self.assertIn("-4 route replace 10.10.30.0/24 via 10.10.30.1 dev incusbr0 proto static", ip_commands)
        self.assertEqual(current_routes, json.loads((self.state_dir / "routes.json").read_text(encoding="utf-8")))

    def test_cleanup_guards_and_recoverable_error_parsing_are_conservative(self):
        managed_root = self.state_dir / "managed-dirs"
        child = managed_root / "web-data"
        outside = self.work_dir / "outside"
        child.mkdir(parents=True)
        outside.mkdir()

        result = self.run_helper(
            f"""
            if is_safe_gc_removal_dir {managed_root}; then printf 'root-safe\n'; else printf 'root-blocked\n'; fi
            if is_safe_gc_removal_dir {child}; then printf 'child-safe\n'; else printf 'child-blocked\n'; fi
            if is_safe_gc_removal_dir {outside}; then printf 'outside-safe\n'; else printf 'outside-blocked\n'; fi
            if is_recoverable_start_error 'Error: Storage volume not found'; then printf 'recoverable\n'; fi
            extract_broken_container_dir_from_delete_error 'Error: Not a Btrfs subvolume: subvolume "/var/lib/incus/storage-pools/default/containers/web"'
            if is_safe_broken_container_dir web {outside}; then printf 'broken-safe\n'; else printf 'broken-blocked\n'; fi
            """
        )

        self.assertEqual(
            [
                "root-blocked",
                "child-safe",
                "outside-blocked",
                "recoverable",
                "/var/lib/incus/storage-pools/default/containers/web",
                "broken-blocked",
            ],
            result.stdout.splitlines(),
        )

    def test_host_suspend_pre_and_post_filter_policy_and_restart_recorded_instances(self):
        meta = lambda policy: json.dumps(
            {
                "version": 1,
                "kind": "incus-machine",
                "hostSuspendPolicy": policy,
            }
        )
        all_instances = [
            {
                "name": "web",
                "project": "default",
                "type": "container",
                "status": "Running",
                "config": {"user.nixos-meta": meta("stop")},
            },
            {
                "name": "vm",
                "project": "lab",
                "type": "virtual-machine",
                "status": "Running",
                "config": {"user.nixos-meta": meta("stop")},
            },
            {
                "name": "ignored",
                "project": "default",
                "type": "container",
                "status": "Running",
                "config": {"user.nixos-meta": meta("ignore")},
            },
            {
                "name": "manual",
                "project": "default",
                "type": "container",
                "status": "Running",
                "config": {},
            },
            {
                "name": "stopped",
                "project": "default",
                "type": "container",
                "status": "Stopped",
                "config": {"user.nixos-meta": meta("stop")},
            },
        ]

        self.run_helper(
            """
            host_suspend_pre_main
            export TEST_INCUS_PROJECT_LIST_JSON='[{"status":"Stopped"}]'
            host_suspend_post_main
            """,
            INCUS_MACHINES_HOST_SUSPEND_INCLUDE_VMS="true",
            INCUS_MACHINES_HOST_SUSPEND_GRACE_TIMEOUT="7",
            TEST_INCUS_LIST_ALL_JSON=json.dumps(all_instances),
        )

        commands = self.read_incus_log()
        self.assertIn(["stop", "--project", "default", "web", "--timeout", "7"], commands)
        self.assertIn(["stop", "--project", "lab", "vm", "--timeout", "7"], commands)
        self.assertIn(["stop", "--project", "default", "manual", "--timeout", "7"], commands)
        self.assertIn(["start", "--project", "default", "web"], commands)
        self.assertIn(["start", "--project", "lab", "vm"], commands)
        self.assertIn(["start", "--project", "default", "manual"], commands)
        flattened = "\n".join(" ".join(command) for command in commands)
        self.assertNotIn("ignored", flattened)
        self.assertNotIn("stopped", flattened)
        self.assertFalse((self.state_dir / "host-suspend/stopped-instances.json").exists())


if __name__ == "__main__":
    unittest.main()
