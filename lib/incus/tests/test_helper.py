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
        return [
            json.loads(line)
            for line in self.incus_log.read_text(encoding="utf-8").splitlines()
        ]

    def clear_incus_log(self):
        self.incus_log.write_text("", encoding="utf-8")

    def machine_meta(self, *, config_hash="hash-1", boot_tag="boot-1", recreate_tag="recreate-1"):
        return {
            "version": 1,
            "kind": "incus-machine",
            "configHash": config_hash,
            "bootTag": boot_tag,
            "recreateTag": recreate_tag,
        }

    def machine_state(
        self,
        *,
        name="web",
        project="default",
        state="running",
        reconcile_policy="auto",
        config_hash="hash-1",
        boot_tag="boot-1",
        recreate_tag="recreate-1",
    ):
        meta = self.machine_meta(
            config_hash=config_hash,
            boot_tag=boot_tag,
            recreate_tag=recreate_tag,
        )
        return {
            "name": name,
            "project": project,
            "imageTag": "image-1",
            "instanceImage": None,
            "imageAlias": "nixos-test",
            "kind": "lxc",
            "state": state,
            "reconcilePolicy": reconcile_policy,
            "configHash": config_hash,
            "bootTag": boot_tag,
            "recreateTag": recreate_tag,
            "desiredDisks": {},
            "desiredDiskGcMetadata": {},
            "createOnlyDevices": {},
            "userMeta": {"user.nixos-meta": json.dumps(meta, separators=(",", ":"))},
            "config": {},
            "ipv4Address": "10.10.30.20",
            "adopt": False,
        }

    def instance_response(
        self,
        *,
        status="Running",
        instance_type="container",
        config_hash="hash-1",
        boot_tag="boot-1",
        recreate_tag="recreate-1",
    ):
        meta = self.machine_meta(
            config_hash=config_hash,
            boot_tag=boot_tag,
            recreate_tag=recreate_tag,
        )
        return {
            "metadata": {
                "status": status,
                "type": instance_type,
                "config": {"user.nixos-meta": json.dumps(meta, separators=(",", ":"))},
                "devices": {"eth0": {"type": "nic", "ipv4.address": "10.10.30.20"}},
            }
        }

    def write_machine_state(self, state):
        state_file = self.work_dir / f"{state['name']}.json"
        state_file.write_text(json.dumps(state), encoding="utf-8")
        return state_file

    def machine_query_responses(self, name="web", response=None):
        if response is None:
            response = self.instance_response()
        return {f"/1.0/instances/{name}?project=default": response}

    def mutation_commands(self):
        commands = []
        for command in self.read_incus_log():
            offset = 0
            project = None
            if command[:2] == ["--project", "default"]:
                offset = 2
                project = "default"
            elif len(command) >= 2 and command[0] == "--project":
                offset = 2
                project = command[1]
            if offset < len(command) and command[offset] in {
                "config",
                "create",
                "delete",
                "start",
                "stop",
            }:
                commands.append((project, command[offset:]))
        return commands

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

    def test_machine_main_recreate_tag_recreates_existing_instance(self):
        state_file = self.write_machine_state(self.machine_state(recreate_tag="recreate-2"))

        self.run_helper(
            "machine_main",
            INCUS_MACHINES_INSTANCE_STATE_FILE=str(state_file),
            TEST_INCUS_QUERY_RESPONSES=json.dumps(
                self.machine_query_responses(
                    response=self.instance_response(recreate_tag="recreate-1")
                )
            ),
        )

        mutations = [command for _, command in self.mutation_commands()]
        self.assertIn(["stop", "web", "--force"], mutations)
        self.assertIn(["delete", "web", "--force"], mutations)
        self.assertIn(["create", "local:nixos-test", "web"], mutations)

    def test_machine_main_boot_tag_restarts_running_but_not_stopped_instances(self):
        running_state = self.write_machine_state(self.machine_state(boot_tag="boot-2"))
        self.run_helper(
            "machine_main",
            INCUS_MACHINES_INSTANCE_STATE_FILE=str(running_state),
            TEST_INCUS_QUERY_RESPONSES=json.dumps(
                self.machine_query_responses(response=self.instance_response(boot_tag="boot-1"))
            ),
        )

        running_mutations = [command for _, command in self.mutation_commands()]
        self.assertIn(["stop", "web", "--force"], running_mutations)
        self.assertNotIn(["delete", "web", "--force"], running_mutations)
        self.assertNotIn(["create", "local:nixos-test", "web"], running_mutations)

        self.clear_incus_log()
        stopped_state = self.write_machine_state(
            self.machine_state(state="stopped", boot_tag="boot-2")
        )
        self.run_helper(
            "machine_main",
            INCUS_MACHINES_INSTANCE_STATE_FILE=str(stopped_state),
            TEST_INCUS_QUERY_RESPONSES=json.dumps(
                self.machine_query_responses(
                    response=self.instance_response(status="Stopped", boot_tag="boot-1")
                )
            ),
        )

        stopped_mutations = [command for _, command in self.mutation_commands()]
        self.assertNotIn(["stop", "web", "--force"], stopped_mutations)
        self.assertNotIn(["start", "web"], stopped_mutations)
        self.assertNotIn(["delete", "web", "--force"], stopped_mutations)
        self.assertNotIn(["create", "local:nixos-test", "web"], stopped_mutations)

    def test_machine_main_declarative_drift_waits_for_explicit_recreate_tag(self):
        drift_state = self.write_machine_state(
            self.machine_state(reconcile_policy="declarative", config_hash="hash-2")
        )
        drift_result = self.run_helper(
            "machine_main",
            INCUS_MACHINES_INSTANCE_STATE_FILE=str(drift_state),
            TEST_INCUS_QUERY_RESPONSES=json.dumps(
                self.machine_query_responses(
                    response=self.instance_response(config_hash="hash-1")
                )
            ),
        )

        drift_mutations = [command for _, command in self.mutation_commands()]
        self.assertIn("pending recreate drift", drift_result.stderr)
        self.assertNotIn(["delete", "web", "--force"], drift_mutations)
        self.assertNotIn(["create", "local:nixos-test", "web"], drift_mutations)

        self.clear_incus_log()
        explicit_state = self.write_machine_state(
            self.machine_state(
                reconcile_policy="declarative",
                config_hash="hash-2",
                recreate_tag="recreate-2",
            )
        )
        self.run_helper(
            "machine_main",
            INCUS_MACHINES_INSTANCE_STATE_FILE=str(explicit_state),
            TEST_INCUS_QUERY_RESPONSES=json.dumps(
                self.machine_query_responses(
                    response=self.instance_response(
                        config_hash="hash-1",
                        recreate_tag="recreate-1",
                    )
                )
            ),
        )

        explicit_mutations = [command for _, command in self.mutation_commands()]
        self.assertIn(["delete", "web", "--force"], explicit_mutations)
        self.assertIn(["create", "local:nixos-test", "web"], explicit_mutations)

    def test_machine_main_ignore_is_noop_unless_policy_is_forced(self):
        ignored_state = self.write_machine_state(
            self.machine_state(reconcile_policy="ignore")
        )

        self.run_helper(
            "machine_main",
            INCUS_MACHINES_INSTANCE_STATE_FILE=str(ignored_state),
            TEST_INCUS_FAIL_PREFIXES=json.dumps([["--project", "default", "info", "web"]]),
        )
        self.assertEqual([], self.read_incus_log())

        self.run_helper(
            "machine_main --force-policy",
            INCUS_MACHINES_INSTANCE_STATE_FILE=str(ignored_state),
            TEST_INCUS_FAIL_PREFIXES=json.dumps([["--project", "default", "info", "web"]]),
            TEST_INCUS_QUERY_RESPONSES=json.dumps(
                self.machine_query_responses(response=self.instance_response(status="Stopped"))
            ),
        )

        forced_mutations = [command for _, command in self.mutation_commands()]
        self.assertIn(["create", "local:nixos-test", "web"], forced_mutations)
        self.assertIn(["start", "web"], forced_mutations)

    def test_settlement_skips_ignored_instances_broadly_but_checks_explicit_selection(self):
        broad_result = self.run_helper(
            "settlement_main --timeout 1 --interval 0",
            INCUS_MACHINES_DECLARED_INSTANCES='["web","ignored"]',
            INCUS_MACHINES_INSTANCE_RECONCILE_POLICIES='{"ignored":"ignore"}',
            TEST_INCUS_QUERY_RESPONSES=json.dumps(
                {
                    "/1.0/instances/web?project=default": self.instance_response(),
                    "/1.0/instances/ignored?project=default": self.instance_response(
                        status="Stopped"
                    ),
                }
            ),
        )

        broad_log = "\n".join(" ".join(command) for command in self.read_incus_log())
        self.assertIn(
            "Skipping ignored Incus instance default/ignored during broad readiness",
            broad_result.stderr,
        )
        self.assertIn("/1.0/instances/web?project=default", broad_log)
        self.assertNotIn("/1.0/instances/ignored?project=default", broad_log)

        self.clear_incus_log()
        explicit_result = self.run_helper(
            "settlement_main --timeout 1 --interval 0 --machine ignored",
            check=False,
            INCUS_MACHINES_DECLARED_INSTANCES='["web","ignored"]',
            INCUS_MACHINES_INSTANCE_RECONCILE_POLICIES='{"ignored":"ignore"}',
            TEST_INCUS_QUERY_RESPONSES=json.dumps(
                {
                    "/1.0/instances/ignored?project=default": self.instance_response(
                        status="Stopped"
                    )
                }
            ),
        )

        explicit_log = "\n".join(" ".join(command) for command in self.read_incus_log())
        self.assertEqual(1, explicit_result.returncode)
        self.assertIn("ignored by declarative reconcile and is not ready", explicit_result.stderr)
        self.assertIn("/1.0/instances/ignored?project=default", explicit_log)


if __name__ == "__main__":
    unittest.main()
