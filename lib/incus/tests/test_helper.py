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
        self.remote_config_dir = self.work_dir / "remote-config"
        self._write_executable(
            self.fake_bin / "incus",
            f"#!/bin/sh\nexec python3 {self.fake_incus} \"$@\"\n",
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
        self._write_executable(
            self.fake_bin / "nproc",
            '#!/bin/sh\nprintf \'%s\\n\' "${TEST_NPROC:-8}"\n',
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
                "TEST_REMOTE_CONFIG_DIR": str(self.remote_config_dir),
                "INCUS_MACHINES_HOST_SUSPEND_STATE_DIR": str(self.state_dir / "host-suspend"),
                "INCUS_MACHINES_MANAGED_GC_DIR_ROOT": str(self.state_dir / "managed-dirs"),
                "INCUS_MACHINES_ETAG_RETRY_DELAY_SEC": "0",
                "TEST_INCUS_FAIL_ONCE_STATE_FILE": str(self.state_dir / "fail-once"),
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
            "network": {"deviceProperties": {"eth0": ["ipv4.address"]}},
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
            "limitConfig": {},
            "limitDevices": {},
            "networkDevices": {"eth0": {"ipv4.address": "10.10.30.20"}},
            "cpuCapacity": None,
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

    def test_remote_delegation_publishes_before_incus_client_setup(self):
        delegation_dir = self.work_dir / "delegation"
        delegation_dir.mkdir()
        client_cert = self.work_dir / "client.crt"
        client_key = self.work_dir / "client.key"
        delegations_file = self.work_dir / "delegations.json"
        client_cert.write_text("client cert\n", encoding="utf-8")
        client_key.write_text("client key\n", encoding="utf-8")
        delegations_file.write_text(
            json.dumps(
                {
                    "abird-platform": {
                        "directory": str(delegation_dir),
                        "fileName": "certs.json",
                        "certificates": [
                            {"name": "abird-nest", "file": str(client_cert)}
                        ],
                        "waitForTrust": True,
                        "waitTimeoutSeconds": 1,
                    }
                }
            ),
            encoding="utf-8",
        )
        self._write_executable(self.fake_bin / "curl", "#!/bin/sh\nexit 0\n")

        self.run_helper(
            "main remote-project-delegations",
            INCUS_MACHINES_REMOTE_PROJECT_DELEGATIONS_FILE=str(delegations_file),
            INCUS_MACHINES_REMOTE_NAME="parent",
            INCUS_MACHINES_REMOTE_ADDRESS="https://127.0.0.1:8443",
            INCUS_MACHINES_REMOTE_PROJECT="abird-platform",
            INCUS_MACHINES_REMOTE_CLIENT_CERT_FILE=str(client_cert),
            INCUS_MACHINES_REMOTE_CLIENT_KEY_FILE=str(client_key),
            INCUS_MACHINES_REMOTE_ACCEPT_CERTIFICATE="true",
            TEST_INCUS_FAIL_PREFIXES=json.dumps([["remote", "add"]]),
        )

        payload = json.loads(
            (delegation_dir / "certs.json").read_text(encoding="utf-8")
        )
        self.assertEqual(1, payload["version"])
        self.assertEqual(
            ["abird-nest"], [cert["name"] for cert in payload["certificates"]]
        )
        self.assertEqual([], self.read_incus_log())

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
        state = self.machine_state(recreate_tag="recreate-2")
        state["limitConfig"] = {
            "limits.cpu": "2",
            "limits.memory": "4GiB",
        }
        state_file = self.write_machine_state(state)

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
        self.assertIn(
            [
                "create",
                "local:nixos-test",
                "web",
                "--config",
                "limits.cpu=2",
                "--config",
                "limits.memory=4GiB",
            ],
            mutations,
        )

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

    def test_limits_main_reconciles_limits_live_and_unsets_only_previously_managed_keys(self):
        current_meta = self.machine_meta()
        current_meta.update(
            {
                "controller": "controller-a",
                "limits": {
                    "configKeys": [
                        "limits.cpu",
                        "limits.memory",
                        "limits.memory.enforce",
                        "limits.memory.swap",
                    ],
                    "deviceProperties": {
                        "eth0": ["limits.max"],
                        "root": ["limits.read"],
                    },
                },
            }
        )
        desired_meta = self.machine_meta()
        desired_meta.update(
            {
                "controller": "controller-a",
                "limits": {
                    "configKeys": [
                        "limits.cpu",
                        "limits.memory",
                        "limits.memory.enforce",
                    ],
                    "deviceProperties": {
                        "eth0": ["limits.egress", "limits.ingress"],
                        "root": ["limits.read"],
                    },
                },
            }
        )
        state = self.machine_state()
        state["limitConfig"] = {
            "limits.cpu": "2",
            "limits.memory": "4GiB",
            "limits.memory.enforce": "hard",
        }
        state["limitDevices"] = {
            "eth0": {"limits.ingress": "200Mbit", "limits.egress": "100Mbit"},
            "root": {"limits.read": "100MiB"},
        }
        state["userMeta"] = {
            "user.nixos-meta": json.dumps(desired_meta, separators=(",", ":"))
        }
        self.write_machine_state(state)

        response = self.instance_response()
        response["metadata"]["config"] = {
            "limits.cpu": "1",
            "limits.memory": "3GiB",
            "limits.memory.enforce": "hard",
            "limits.memory.swap": "false",
            "security.nesting": "true",
            "user.nixos-meta": json.dumps(current_meta, separators=(",", ":")),
        }
        response["metadata"]["devices"] = {
            "eth0": {
                "type": "nic",
                "ipv4.address": "10.10.30.20",
                "limits.max": "50Mbit",
                "limits.priority": "7",
            },
            "root": {"type": "disk", "path": "/", "limits.read": "50MiB"},
        }

        self.run_helper(
            "limits_main --all",
            INCUS_MACHINES_CONTROLLER_ID="controller-a",
            INCUS_MACHINES_DECLARED_INSTANCES='["web"]',
            INCUS_MACHINES_INSTANCE_NAMES='{"web":"web"}',
            INCUS_MACHINES_INSTANCE_PROJECTS='{"web":"default"}',
            INCUS_MACHINES_INSTANCE_RECONCILE_POLICIES='{"web":"auto"}',
            INCUS_MACHINES_INSTANCE_STATE_DIR=str(self.work_dir),
            TEST_INCUS_QUERY_RESPONSES=json.dumps(self.machine_query_responses(response=response)),
        )

        mutations = [command for _, command in self.mutation_commands()]
        self.assertIn(["config", "unset", "web", "limits.memory.swap"], mutations)
        self.assertIn(
            ["config", "set", "web", "limits.cpu=2", "limits.memory=4GiB"],
            mutations,
        )
        self.assertIn(["config", "device", "unset", "web", "eth0", "limits.max"], mutations)
        self.assertIn(
            [
                "config",
                "device",
                "set",
                "web",
                "eth0",
                "limits.ingress=200Mbit",
                "limits.egress=100Mbit",
            ],
            mutations,
        )
        self.assertIn(
            ["config", "device", "set", "web", "root", "limits.read=100MiB"],
            mutations,
        )
        flattened = "\n".join(" ".join(command) for command in mutations)
        self.assertNotIn("security.nesting", flattened)
        self.assertNotIn("limits.priority", flattened)
        self.assertNotIn("stop web", flattened)
        self.assertNotIn("delete web", flattened)
        self.assertNotIn("create local:nixos-test web", flattened)

    def test_limits_main_defers_declared_device_until_lifecycle_attaches_it(self):
        state = self.machine_state()
        state["limitDevices"] = {"state": {"limits.read": "100MiB"}}
        self.write_machine_state(state)

        result = self.run_helper(
            "limits_main --all",
            INCUS_MACHINES_DECLARED_INSTANCES='["web"]',
            INCUS_MACHINES_INSTANCE_NAMES='{"web":"web"}',
            INCUS_MACHINES_INSTANCE_PROJECTS='{"web":"default"}',
            INCUS_MACHINES_INSTANCE_RECONCILE_POLICIES='{"web":"auto"}',
            INCUS_MACHINES_INSTANCE_STATE_DIR=str(self.work_dir),
            TEST_INCUS_QUERY_RESPONSES=json.dumps(self.machine_query_responses()),
            TEST_INCUS_FAIL_PREFIXES=json.dumps(
                [["--project", "default", "config", "device", "override", "web", "state"]]
            ),
            TEST_INCUS_FAIL_MESSAGE="The profile device doesn't exist",
        )

        self.assertIn(
            "Skipping limits for unavailable device default/web/state until lifecycle reconciliation",
            result.stdout,
        )

    def test_live_network_reconciliation_unsets_only_manager_owned_properties(self):
        current_meta = {
            "network": {
                "deviceProperties": {
                    "eth0": [
                        "ipv4.address",
                        "ipv4.routes",
                        "ipv6.address",
                        "security.ipv4_filtering",
                        "security.ipv6_filtering",
                    ]
                }
            }
        }
        current_devices = {
            "eth0": {
                "type": "nic",
                "network": "incusbr0",
                "ipv4.address": "10.10.30.20",
                "ipv4.routes": "10.10.31.0/24",
                "ipv6.address": "fd42:30::20",
                "security.ipv4_filtering": "true",
                "security.ipv6_filtering": "true",
                "limits.max": "250Mbit",
            }
        }
        desired_devices = {
            "eth0": {
                "ipv4.address": "10.10.30.20",
                "ipv4.routes": "10.10.32.0/24",
                "security.ipv4_filtering": "true",
            }
        }

        self.run_helper(
            f"""
            reconcile_instance_network \
              web \
              '{json.dumps(current_devices, separators=(",", ":"))}' \
              '{json.dumps(current_meta, separators=(",", ":"))}' \
              '{json.dumps(desired_devices, separators=(",", ":"))}'
            """
        )

        mutations = [command for _, command in self.mutation_commands()]
        self.assertIn(
            ["config", "device", "unset", "web", "eth0", "ipv6.address"],
            mutations,
        )
        self.assertIn(
            [
                "config",
                "device",
                "unset",
                "web",
                "eth0",
                "security.ipv6_filtering",
            ],
            mutations,
        )
        self.assertIn(
            [
                "config",
                "device",
                "set",
                "web",
                "eth0",
                "ipv4.routes=10.10.32.0/24",
            ],
            mutations,
        )
        flattened = "\n".join(" ".join(command) for command in mutations)
        self.assertNotIn("network incusbr0", flattened)
        self.assertNotIn("limits.max", flattened)
        self.assertNotIn("stop web", flattened)
        self.assertNotIn("delete web", flattened)

    def test_live_network_reconciliation_overrides_inherited_device(self):
        desired_devices = {
            "eth0": {
                "ipv4.address": "10.10.30.20",
                "ipv4.routes": "10.10.31.0/24",
                "ipv6.address": "fd42:30::20",
                "ipv6.routes": "fd42:31::/64",
                "security.ipv4_filtering": "true",
                "security.ipv6_filtering": "true",
            }
        }

        self.run_helper(
            f"""
            reconcile_instance_network \
              web \
              '{{}}' \
              '{{}}' \
              '{json.dumps(desired_devices, separators=(",", ":"))}'
            """
        )

        mutations = [command for _, command in self.mutation_commands()]
        self.assertIn(
            [
                "config",
                "device",
                "override",
                "web",
                "eth0",
                "ipv4.address=10.10.30.20",
                "ipv4.routes=10.10.31.0/24",
                "ipv6.address=fd42:30::20",
                "ipv6.routes=fd42:31::/64",
                "security.ipv4_filtering=true",
                "security.ipv6_filtering=true",
            ],
            mutations,
        )

    def test_limits_main_resolves_relative_cpu_count_against_effective_parent_cpus(self):
        current_meta = self.machine_meta()
        current_meta["limits"] = {
            "configKeys": ["limits.cpu"],
            "deviceProperties": {},
        }
        desired_meta = self.machine_meta()
        desired_meta["limits"] = {
            "configKeys": ["limits.cpu"],
            "deviceProperties": {},
        }
        state = self.machine_state()
        state["limitConfig"] = {"limits.cpu": "80%"}
        state["userMeta"] = {
            "user.nixos-meta": json.dumps(desired_meta, separators=(",", ":"))
        }
        self.write_machine_state(state)

        response = self.instance_response()
        response["metadata"]["config"] = {
            "limits.cpu": "2",
            "user.nixos-meta": json.dumps(current_meta, separators=(",", ":")),
        }

        result = self.run_helper(
            "limits_main --all",
            INCUS_MACHINES_DECLARED_INSTANCES='["web"]',
            INCUS_MACHINES_INSTANCE_NAMES='{"web":"web"}',
            INCUS_MACHINES_INSTANCE_PROJECTS='{"web":"default"}',
            INCUS_MACHINES_INSTANCE_RECONCILE_POLICIES='{"web":"auto"}',
            INCUS_MACHINES_INSTANCE_STATE_DIR=str(self.work_dir),
            TEST_INCUS_QUERY_RESPONSES=json.dumps(self.machine_query_responses(response=response)),
            TEST_NPROC="22",
        )

        mutations = [command for _, command in self.mutation_commands()]
        self.assertIn(["config", "set", "web", "limits.cpu=17"], mutations)
        self.assertIn(
            "Resolved CPU count for web: 80% of 22 available CPUs = 17",
            result.stderr,
        )

    def test_relative_cpu_count_fails_closed_for_invalid_runtime_state(self):
        result = self.run_helper(
            "resolve_relative_limit_config web '{\"limits.cpu\":\"101%\"}' ''",
            check=False,
            TEST_NPROC="22",
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("Invalid relative CPU count for web: 101%", result.stderr)

    def test_machine_creation_resolves_relative_cpu_count_before_incus_mutation(self):
        state = self.machine_state()
        state["limitConfig"] = {"limits.cpu": "80%"}
        state_file = self.write_machine_state(state)

        self.run_helper(
            "machine_main",
            INCUS_MACHINES_INSTANCE_STATE_FILE=str(state_file),
            TEST_INCUS_FAIL_PREFIXES=json.dumps(
                [["--project", "default", "info", "web"]]
            ),
            TEST_INCUS_QUERY_RESPONSES=json.dumps(
                self.machine_query_responses(
                    response=self.instance_response(status="Stopped")
                )
            ),
            TEST_NPROC="22",
        )

        mutations = [command for _, command in self.mutation_commands()]
        self.assertIn(
            [
                "create",
                "local:nixos-test",
                "web",
                "--config",
                "limits.cpu=17",
            ],
            mutations,
        )
        self.assertIn(["config", "set", "web", "limits.cpu=17"], mutations)

    def test_machine_creation_passes_pool_default_size_to_new_storage_volume(self):
        state = self.machine_state()
        state["desiredDisks"] = {
            "state": {
                "type": "disk",
                "source": "web",
                "pool": "default",
                "path": "/var/lib",
            }
        }
        state_file = self.write_machine_state(state)

        self.run_helper(
            "machine_main",
            INCUS_MACHINES_INSTANCE_STATE_FILE=str(state_file),
            TEST_INCUS_FAIL_PREFIXES=json.dumps(
                [
                    ["--project", "default", "info", "web"],
                    [
                        "--project",
                        "default",
                        "storage",
                        "volume",
                        "show",
                        "default",
                        "web",
                    ],
                ]
            ),
            TEST_INCUS_QUERY_RESPONSES=json.dumps(self.machine_query_responses()),
            TEST_INCUS_STORAGE_VOLUME_SIZE="32GiB",
        )

        commands = self.read_incus_log()
        self.assertIn(
            ["--project", "default", "storage", "get", "default", "volume.size"],
            commands,
        )
        self.assertIn(
            [
                "--project",
                "default",
                "storage",
                "volume",
                "create",
                "default",
                "web",
                "size=32GiB",
            ],
            commands,
        )

    def test_machine_creation_keeps_explicit_volume_size_off_disk_device(self):
        state = self.machine_state()
        state["desiredDisks"] = {
            "state": {
                "type": "disk",
                "source": "web",
                "pool": "default",
                "path": "/var/lib",
                "size": "32GiB",
            }
        }
        state_file = self.write_machine_state(state)

        self.run_helper(
            "machine_main",
            INCUS_MACHINES_INSTANCE_STATE_FILE=str(state_file),
            TEST_INCUS_FAIL_PREFIXES=json.dumps(
                [
                    ["--project", "default", "info", "web"],
                    [
                        "--project",
                        "default",
                        "storage",
                        "volume",
                        "show",
                        "default",
                        "web",
                    ],
                ]
            ),
            TEST_INCUS_QUERY_RESPONSES=json.dumps(self.machine_query_responses()),
        )

        commands = self.read_incus_log()
        self.assertIn(
            [
                "--project",
                "default",
                "storage",
                "volume",
                "create",
                "default",
                "web",
                "size=32GiB",
            ],
            commands,
        )
        device_add = next(
            command
            for command in commands
            if command[:7]
            == ["--project", "default", "config", "device", "add", "web", "state"]
        )
        self.assertNotIn("size=32GiB", device_add)

    def test_remote_relative_cpu_count_requires_explicit_capacity(self):
        result = self.run_helper(
            "resolve_relative_limit_config web '{\"limits.cpu\":\"80%\"}' ''",
            check=False,
            INCUS_MACHINES_REMOTE_NAME="parent",
        )

        self.assertNotEqual(0, result.returncode)
        self.assertIn(
            "remote Incus targets require an explicit CPU capacity",
            result.stderr,
        )

        resolved = self.run_helper(
            "resolve_relative_limit_config web '{\"limits.cpu\":\"80%\"}' 22",
            INCUS_MACHINES_REMOTE_NAME="parent",
        )
        self.assertEqual('{"limits.cpu":"17"}', resolved.stdout.strip())

    def test_device_update_retries_one_etag_conflict(self):
        result = self.run_helper(
            """
            set_device_config_json_if_changed \
                web root \
                '{"type":"disk","path":"/","limits.read":"50MiB"}' \
                '{"limits.read":"100MiB"}'
            """,
            TEST_INCUS_FAIL_ONCE_PREFIXES=json.dumps(
                [["--project", "default", "config", "device", "set", "web", "root"]]
            ),
        )

        commands = self.read_incus_log()
        expected = [
            "--project",
            "default",
            "config",
            "device",
            "set",
            "web",
            "root",
            "limits.read=100MiB",
        ]
        self.assertEqual(2, commands.count(expected))
        self.assertIn("retrying (1/3)", result.stderr)

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

    @staticmethod
    def proxy_definition(**changes):
        return {
            "type": "proxy",
            "bind": "instance",
            "listen": "tcp:10.10.0.10:5000",
            "connect": "tcp:127.0.0.1:5000",
            **changes,
        }

    @staticmethod
    def payload_hash(payload):
        import hashlib

        return hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        ).hexdigest()

    def proxy_state(self, proxies, *, immutable_config=None, **kwargs):
        state = self.machine_state(**kwargs)
        payload = {
            "preseedTag": "0",
            "config": immutable_config or {},
            "kind": "lxc",
            "project": "default",
            "image": {"alias": "nixos-test"},
            "createOnlyDevices": {},
        }
        state.update(
            {
                "configHashPayload": payload,
                "configHash": self.payload_hash(payload),
                "legacyConfigHash": self.payload_hash({**payload, "createOnlyDevices": proxies}),
                "proxyDevices": proxies,
            }
        )
        meta = json.loads(state["userMeta"]["user.nixos-meta"])
        meta.update(configHash=state["configHash"], proxyDevices=sorted(proxies))
        state["userMeta"]["user.nixos-meta"] = json.dumps(meta)
        return state

    def install_proxy_instance(
        self, proxies, *, legacy=False, owned=None, status="Running", immutable_config=None
    ):
        state = self.proxy_state(proxies, immutable_config=immutable_config)
        response = self.instance_response(status=status)
        meta = json.loads(state["userMeta"]["user.nixos-meta"])
        if legacy:
            meta.pop("proxyDevices")
            meta["configHash"] = state["legacyConfigHash"]
        elif owned is not None:
            meta["proxyDevices"] = owned
        response["metadata"]["config"]["user.nixos-meta"] = json.dumps(meta)
        response["metadata"]["devices"].update(json.loads(json.dumps(proxies)))
        self.proxy_instance_file = self.work_dir / "instance.json"
        self.proxy_instance_file.write_text(json.dumps(response))
        return response

    def run_proxy_state(self, state, *, mode="live", check=True, **env):
        state_file = self.write_machine_state(state)
        return self.run_helper(
            "limits_main --all" if mode == "live" else "machine_main",
            check=check,
            INCUS_MACHINES_DECLARED_INSTANCES='["web"]',
            INCUS_MACHINES_INSTANCE_STATE_DIR=str(self.work_dir),
            INCUS_MACHINES_INSTANCE_STATE_FILE=str(state_file),
            INCUS_MACHINES_INSTANCE_RECONCILE_POLICIES=json.dumps(
                {"web": state["reconcilePolicy"]}
            ),
            TEST_INCUS_INSTANCE_FILE=str(self.proxy_instance_file),
            **env,
        )

    def proxy_observed(self):
        response = json.loads(self.proxy_instance_file.read_text())
        return response["metadata"]["devices"], json.loads(
            response["metadata"]["config"]["user.nixos-meta"]
        )

    def assert_no_instance_lifecycle(self):
        self.assertEqual(
            [],
            [
                c
                for _, c in self.mutation_commands()
                if c[0] in {"create", "delete", "start", "stop"}
            ],
        )

    def test_proxy_live_add_update_clear_rename_remove_and_idempotency(self):
        for policy in ("auto", "declarative"):
            with self.subTest(policy=policy):
                self.clear_incus_log()
                self.install_proxy_instance({})
                original = self.proxy_definition(proxy_protocol="true")
                self.run_proxy_state(self.proxy_state({"cache": original}, reconcile_policy=policy))
                self.assertEqual(original, self.proxy_observed()[0]["cache"])
                updated = self.proxy_definition(connect="tcp:127.0.0.1:5001")
                self.run_proxy_state(self.proxy_state({"cache": updated}, reconcile_policy=policy))
                commands = [c for _, c in self.mutation_commands()]
                self.assertTrue(
                    any(
                        c[:4] == ["config", "device", "set", "web"]
                        and "proxy_protocol=" in c
                        and "connect=tcp:127.0.0.1:5001" in c
                        for c in commands
                    )
                )
                self.assertFalse(any(c[:3] == ["config", "device", "unset"] for c in commands))
                self.run_proxy_state(
                    self.proxy_state({"renamed": updated}, reconcile_policy=policy)
                )
                devices, meta = self.proxy_observed()
                self.assertNotIn("cache", devices)
                self.assertEqual(updated, devices["renamed"])
                self.assertEqual(["renamed"], meta["proxyDevices"])
                self.assert_no_instance_lifecycle()
                self.clear_incus_log()
                self.run_proxy_state(
                    self.proxy_state({"renamed": updated}, reconcile_policy=policy)
                )
                self.assertEqual([], self.mutation_commands())
                self.run_proxy_state(self.proxy_state({}, reconcile_policy=policy))
                self.assertNotIn("renamed", self.proxy_observed()[0])
                self.assertEqual([], self.proxy_observed()[1]["proxyDevices"])
                self.assert_no_instance_lifecycle()

    def test_proxy_legacy_hash_migrates_changes_and_removals_without_recreation(self):
        for mode in ("live", "machine"):
            for desired in (
                {},
                {"cache": self.proxy_definition(connect="tcp:127.0.0.1:5001")},
                {"renamed": self.proxy_definition()},
            ):
                with self.subTest(mode=mode, desired=desired):
                    self.clear_incus_log()
                    self.install_proxy_instance({"cache": self.proxy_definition()}, legacy=True)
                    state = self.proxy_state(desired)
                    self.run_proxy_state(state, mode=mode)
                    devices, meta = self.proxy_observed()
                    self.assertEqual(sorted(desired), meta["proxyDevices"])
                    self.assertEqual(state["configHash"], meta["configHash"])
                    self.assertEqual(
                        desired, {n: v for n, v in devices.items() if v["type"] == "proxy"}
                    )
                    self.assert_no_instance_lifecycle()

    def test_proxy_legacy_declared_hash_recovers_live_drift_without_claiming_foreign_devices(self):
        old = {"cache": self.proxy_definition()}
        response = self.install_proxy_instance(old, legacy=True)
        response["metadata"]["devices"]["cache"]["connect"] = "tcp:127.0.0.1:9999"
        foreign = self.proxy_definition(listen="tcp:10.10.0.10:6000")
        response["metadata"]["devices"]["manual"] = foreign
        self.proxy_instance_file.write_text(json.dumps(response))
        self.run_proxy_state(self.proxy_state(old))
        devices, meta = self.proxy_observed()
        self.assertEqual(old["cache"], devices["cache"])
        self.assertEqual(foreign, devices["manual"])
        self.assertEqual(["cache"], meta["proxyDevices"])
        self.assert_no_instance_lifecycle()

    def test_proxy_legacy_ambiguous_hash_fails_closed(self):
        for mode in ("live", "machine"):
            with self.subTest(mode=mode):
                self.clear_incus_log()
                self.install_proxy_instance({"cache": self.proxy_definition()}, legacy=True)
                before = self.proxy_instance_file.read_bytes()
                state = self.proxy_state(
                    {"cache": self.proxy_definition(connect="tcp:127.0.0.1:6000")},
                    immutable_config={"security.nesting": "true"},
                )
                result = self.run_proxy_state(state, mode=mode, check=False)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("Cannot prove legacy", result.stderr)
                self.assertEqual(before, self.proxy_instance_file.read_bytes())
                self.assertEqual([], self.mutation_commands())

    def test_proxy_conflicts_fail_before_mutation(self):
        for conflict in ("foreign", "type", "inherited", "controller"):
            with self.subTest(conflict=conflict):
                self.clear_incus_log()
                response = self.install_proxy_instance(
                    {"cache": self.proxy_definition()}, owned=[] if conflict == "foreign" else None
                )
                if conflict == "type":
                    response["metadata"]["devices"]["cache"] = {"type": "disk", "source": "/keep"}
                if conflict == "inherited":
                    response["metadata"]["expanded_devices"] = {
                        "cache": response["metadata"]["devices"].pop("cache")
                    }
                if conflict == "controller":
                    meta = json.loads(response["metadata"]["config"]["user.nixos-meta"])
                    meta["controller"] = "other"
                    response["metadata"]["config"]["user.nixos-meta"] = json.dumps(meta)
                self.proxy_instance_file.write_text(json.dumps(response))
                before = self.proxy_instance_file.read_bytes()
                result = self.run_proxy_state(
                    self.proxy_state({"cache": self.proxy_definition()}),
                    check=False,
                    INCUS_MACHINES_CONTROLLER_ID="owner",
                )
                self.assertNotEqual(0, result.returncode)
                self.assertEqual(before, self.proxy_instance_file.read_bytes())
                self.assertEqual([], self.mutation_commands())

    def test_proxy_failure_reservations_make_partial_additions_retryable_and_removable(self):
        for retry in (True, False):
            with self.subTest(retry=retry):
                self.clear_incus_log()
                self.install_proxy_instance({})
                desired = {
                    "a": self.proxy_definition(),
                    "b": self.proxy_definition(listen="tcp:10.10.0.10:5001"),
                }
                result = self.run_proxy_state(
                    self.proxy_state(desired),
                    check=False,
                    TEST_INCUS_FAIL_PREFIXES=json.dumps(
                        [["--project", "default", "config", "device", "add", "web", "b"]]
                    ),
                )
                self.assertNotEqual(0, result.returncode)
                devices, meta = self.proxy_observed()
                self.assertIn("a", devices)
                self.assertNotIn("b", devices)
                self.assertEqual(["a", "b"], meta["proxyDevices"])
                self.run_proxy_state(self.proxy_state(desired if retry else {}))
                devices, meta = self.proxy_observed()
                self.assertEqual(sorted(desired) if retry else [], meta["proxyDevices"])
                self.assertEqual(retry, "a" in devices)
                self.assertEqual(retry, "b" in devices)
                self.assert_no_instance_lifecycle()

    def test_proxy_update_and_remove_failures_do_not_replace_guest(self):
        for mode in ("live", "machine"):
            for operation in ("set", "remove"):
                with self.subTest(mode=mode, operation=operation):
                    self.clear_incus_log()
                    old = {"cache": self.proxy_definition()}
                    self.install_proxy_instance(old)
                    desired = (
                        {}
                        if operation == "remove"
                        else {"cache": self.proxy_definition(connect="tcp:127.0.0.1:6000")}
                    )
                    result = self.run_proxy_state(
                        self.proxy_state(desired),
                        mode=mode,
                        check=False,
                        TEST_INCUS_FAIL_PREFIXES=json.dumps(
                            [["--project", "default", "config", "device", operation]]
                        ),
                    )
                    self.assertNotEqual(0, result.returncode)
                    self.assertEqual(old["cache"], self.proxy_observed()[0]["cache"])
                    self.assert_no_instance_lifecycle()

    def test_proxy_live_path_respects_stopped_missing_and_ignored_guests(self):
        for case in ("stopped", "missing", "ignored"):
            with self.subTest(case=case):
                self.clear_incus_log()
                response = self.install_proxy_instance(
                    {}, status="Stopped" if case == "stopped" else "Running"
                )
                if case == "missing":
                    response["exists"] = False
                    self.proxy_instance_file.write_text(json.dumps(response))
                state = self.proxy_state(
                    {"cache": self.proxy_definition()},
                    state="stopped" if case == "stopped" else "running",
                    reconcile_policy="ignore" if case == "ignored" else "auto",
                )
                self.run_proxy_state(state)
                self.assertEqual(case == "stopped", "cache" in self.proxy_observed()[0])
                self.assert_no_instance_lifecycle()
                if case != "stopped":
                    self.assertEqual([], self.mutation_commands())

    def test_proxy_fresh_guest_receives_device_before_start(self):
        self.install_proxy_instance({})
        self.proxy_instance_file.write_text(json.dumps({"exists": False}))
        self.run_proxy_state(self.proxy_state({"cache": self.proxy_definition()}), mode="machine")
        commands = [c for _, c in self.mutation_commands()]
        add_index = next(
            i
            for i, c in enumerate(commands)
            if c[:5] == ["config", "device", "add", "web", "cache"]
        )
        self.assertLess(add_index, commands.index(["start", "web"]))
        self.assertEqual(
            "Running", json.loads(self.proxy_instance_file.read_text())["metadata"]["status"]
        )

    def test_proxy_migration_does_not_mask_explicit_recreation_or_modern_immutable_drift(self):
        for legacy in (True, False):
            with self.subTest(legacy=legacy):
                self.clear_incus_log()
                self.install_proxy_instance({"cache": self.proxy_definition()}, legacy=legacy)
                state = self.proxy_state(
                    {"cache": self.proxy_definition()},
                    immutable_config={"security.nesting": "true"},
                    recreate_tag="recreate-2" if legacy else "recreate-1",
                )
                self.run_proxy_state(state, mode="machine")
                commands = [c for _, c in self.mutation_commands()]
                self.assertIn(["delete", "web", "--force"], commands)
                self.assertIn(["create", "local:nixos-test", "web"], commands)


    def test_proxy_metadata_failure_prevents_device_mutation(self):
        self.install_proxy_instance({})
        result = self.run_proxy_state(
            self.proxy_state({"cache": self.proxy_definition()}),
            check=False,
            TEST_INCUS_FAIL_PREFIXES=json.dumps(
                [["--project", "default", "config", "set", "web"]]
            ),
        )
        self.assertNotEqual(0, result.returncode)
        self.assertNotIn("cache", self.proxy_observed()[0])
        self.assertFalse(any(c[:2] == ["config", "device"] for _, c in self.mutation_commands()))
        self.assert_no_instance_lifecycle()

    def test_proxy_updates_preserve_pending_declarative_immutable_drift(self):
        self.install_proxy_instance({"cache": self.proxy_definition()})
        old_hash = self.proxy_observed()[1]["configHash"]
        desired = {"cache": self.proxy_definition(connect="tcp:127.0.0.1:5001")}
        state = self.proxy_state(
            desired, reconcile_policy="declarative", immutable_config={"security.nesting": "true"}
        )
        result = self.run_proxy_state(state, mode="machine")
        self.assertIn("pending recreate drift", result.stderr)
        self.assertEqual(old_hash, self.proxy_observed()[1]["configHash"])
        self.assertEqual(desired["cache"], self.proxy_observed()[0]["cache"])
        self.assert_no_instance_lifecycle()

    def test_proxy_native_updates_retry_etag_without_recreating(self):
        self.install_proxy_instance({"cache": self.proxy_definition()})
        state = self.proxy_state({"cache": self.proxy_definition(connect="tcp:127.0.0.1:5001")})
        self.run_proxy_state(
            state,
            TEST_INCUS_FAIL_ONCE_PREFIXES=json.dumps(
                [["--project", "default", "config", "device", "set"]]
            ),
        )
        calls = [c for _, c in self.mutation_commands() if c[:3] == ["config", "device", "set"]]
        self.assertEqual(2, len(calls))
        self.assertEqual(state["proxyDevices"]["cache"], self.proxy_observed()[0]["cache"])
        self.assert_no_instance_lifecycle()


    def test_proxy_retired_missing_override_does_not_touch_inherited_device(self):
        response = self.install_proxy_instance({}, owned=["retired"])
        inherited = self.proxy_definition()
        response["metadata"]["expanded_devices"] = {"retired": inherited}
        self.proxy_instance_file.write_text(json.dumps(response))
        self.run_proxy_state(self.proxy_state({}))
        self.assertEqual([], self.proxy_observed()[1]["proxyDevices"])
        after = json.loads(self.proxy_instance_file.read_text())
        self.assertEqual(inherited, after["metadata"]["expanded_devices"]["retired"])
        self.assertFalse(any(c[:2] == ["config", "device"] for _, c in self.mutation_commands()))
        self.assert_no_instance_lifecycle()


if __name__ == "__main__":
    unittest.main()
