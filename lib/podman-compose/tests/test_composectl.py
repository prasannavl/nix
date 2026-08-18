import json
import os
import pwd
import subprocess
import tempfile
import unittest
from pathlib import Path


class PodmanComposeCtlTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[3]
        cls.script = cls.repo_root / "lib/podman-compose/composectl.sh"
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def test_expected_units_filters_by_owner_autostart_and_desired_state(self):
        with tempfile.TemporaryDirectory(prefix="podman-composectl-test.", dir=self.tmp_root) as tmp:
            registry = Path(tmp) / "registry.json"
            registry.write_text(
                json.dumps(
                    {
                        "alice-web": {
                            "user": "alice",
                            "unit": "alice-web.service",
                            "readyUnit": "alice-web-ready.target",
                            "managedUnit": "alice-managed.target",
                            "privateRuntimeUnits": ["alice-web-container.service"],
                            "autoStart": True,
                            "state": "running",
                        },
                        "alice-manual": {
                            "user": "alice",
                            "unit": "alice-manual.service",
                            "autoStart": False,
                            "state": "running",
                        },
                        "alice-stopped": {
                            "user": "alice",
                            "unit": "alice-stopped.service",
                            "autoStart": True,
                            "state": "stopped",
                        },
                        "bob-web": {
                            "user": "bob",
                            "unit": "bob-web.service",
                            "autoStart": True,
                            "state": "running",
                        },
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    f'registry="$1" helper=/bin/true; source "$2"; main expected-units alice',
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                ],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )
            held_result = subprocess.run(
                [
                    "bash",
                    "-c",
                    (
                        'registry="$1" helper=/bin/true; source "$2"; '
                        "main expected-units alice --exclude-unit alice-web.service"
                    ),
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                ],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )

        self.assertEqual(
            [
                "alice-managed.target",
                "alice-web-container.service",
                "alice-web-ready.target",
                "alice-web.service",
            ],
            result.stdout.splitlines(),
        )
        self.assertEqual(["alice-managed.target"], held_result.stdout.splitlines())

    def test_expected_runtime_delegates_quadlet_verification_to_systemd(self):
        owner = pwd.getpwuid(os.getuid()).pw_name
        expected_labels = {
            "io.abird.podman-compose.backend": "quadlet",
            "io.abird.podman-compose.instance": "native",
            "io.abird.podman-compose.service": "web",
        }
        with tempfile.TemporaryDirectory(prefix="podman-composectl-test.", dir=self.tmp_root) as tmp:
            registry = Path(tmp) / "registry.json"
            registry.write_text(
                json.dumps(
                    {
                        "native": {
                            "backend": "quadlet",
                            "user": owner,
                            "uid": str(os.getuid()),
                            "unit": "native.service",
                            "serviceName": "native",
                            "expectedContainers": [
                                {"name": "native-container", "labels": expected_labels}
                            ],
                            "autoStart": True,
                            "state": "running",
                        }
                    }
                ),
                encoding="utf-8",
            )
            containers = [
                {
                    "State": "running",
                    "Health": "unhealthy",
                    "Labels": expected_labels,
                },
                {
                    "State": "running",
                    "Labels": {
                        **expected_labels,
                        "io.abird.podman-compose.service": "unrelated",
                    },
                },
            ]
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """
                    registry="$1"
                    helper=/bin/true
                    source "$2"
                    require_runtime_dir() { :; }
                    require_user_bus() { :; }
                    getent() { printf '%s\n' 'test:x:1:1::/:/bin/sh'; }
                    run_as_owner() { return 1; }
                    main expected-runtime "$3"
                    """,
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                    owner,
                ],
                cwd=self.repo_root,
                env={**os.environ, "TEST_CONTAINERS_JSON": json.dumps(containers)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )
            held_result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """
                    registry="$1"
                    helper=/bin/true
                    source "$2"
                    run_as_owner() { printf '%s\n' unexpected-runtime-query; return 1; }
                    main expected-runtime "$3" --exclude-unit native.service
                    """,
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                    owner,
                ],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )

        self.assertEqual(
            ["inactive-unit service=native unit=native.service"],
            result.stdout.splitlines(),
        )
        self.assertEqual([], held_result.stdout.splitlines())

    def test_expected_units_discovers_quadlet_units_from_systemd_graph(self):
        owner = pwd.getpwuid(os.getuid()).pw_name
        with tempfile.TemporaryDirectory(prefix="podman-composectl-test.", dir=self.tmp_root) as tmp:
            registry = Path(tmp) / "registry.json"
            registry.write_text(
                json.dumps(
                    {
                        "native": {
                            "backend": "quadlet",
                            "user": owner,
                            "uid": str(os.getuid()),
                            "unit": "native.service",
                            "readyUnit": "native-ready.target",
                            "managedUnit": "owner-managed.target",
                            "serviceName": "native",
                            "autoStart": True,
                            "state": "running",
                        }
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """
                    registry="$1"
                    helper=/bin/true
                    source "$2"
                    run_as_owner() {
                      printf '%s\\n' \
                        native-stage.service \
                        native-web-container.service \
                        native-image-deadbeef-image.service \
                        podman-user-wait-network-online.service
                    }
                    main expected-units "$3"
                    """,
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                    owner,
                ],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )

        self.assertEqual(
            [
                "native-image-deadbeef-image.service",
                "native-ready.target",
                "native-stage.service",
                "native-web-container.service",
                "native.service",
                "owner-managed.target",
            ],
            result.stdout.splitlines(),
        )

    def test_expected_units_fails_closed_when_quadlet_graph_query_fails(self):
        owner = pwd.getpwuid(os.getuid()).pw_name
        with tempfile.TemporaryDirectory(prefix="podman-composectl-test.", dir=self.tmp_root) as tmp:
            registry = Path(tmp) / "registry.json"
            registry.write_text(
                json.dumps(
                    {
                        "native": {
                            "backend": "quadlet",
                            "user": owner,
                            "uid": str(os.getuid()),
                            "unit": "native.service",
                            "readyUnit": "native-ready.target",
                            "managedUnit": "owner-managed.target",
                            "serviceName": "native",
                            "autoStart": True,
                            "state": "running",
                        }
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """
                    registry="$1"
                    helper=/bin/true
                    source "$2"
                    run_as_owner() { return 1; }
                    main expected-units "$3"
                    """,
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                    owner,
                ],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], result.stdout.splitlines())
        self.assertIn("unable to discover Quadlet runtime units", result.stderr)

    def test_expected_runtime_checks_every_quadlet_graph_unit(self):
        owner = pwd.getpwuid(os.getuid()).pw_name
        with tempfile.TemporaryDirectory(prefix="podman-composectl-test.", dir=self.tmp_root) as tmp:
            registry = Path(tmp) / "registry.json"
            registry.write_text(
                json.dumps(
                    {
                        "native": {
                            "backend": "quadlet",
                            "user": owner,
                            "uid": str(os.getuid()),
                            "unit": "native.service",
                            "serviceName": "native",
                            "autoStart": True,
                            "state": "running",
                        }
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """
                    registry="$1"
                    helper=/bin/true
                    source "$2"
                    require_runtime_dir() { :; }
                    require_user_bus() { :; }
                    getent() { printf '%s\n' 'test:x:1:1::/:/bin/sh'; }
                    run_as_owner() {
                      shift 4
                      case "$*" in
                        *' is-active --quiet native.service') return 0 ;;
                        *' start native-verify.service') return 0 ;;
                        *' list-dependencies '*)
                          printf '%s\n' native-stage.service native-web-container.service
                          ;;
                        *' is-active --quiet native-stage.service') return 0 ;;
                        *' is-active --quiet native-web-container.service') return 3 ;;
                        *) return 64 ;;
                      esac
                    }
                    main expected-runtime "$3"
                    """,
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                    owner,
                ],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )

        self.assertEqual(
            ["inactive-unit service=native unit=native-web-container.service"],
            result.stdout.splitlines(),
        )

    def test_expected_runtime_reads_state_larger_than_arg_max_without_argv(self):
        owner = pwd.getpwuid(os.getuid()).pw_name
        with tempfile.TemporaryDirectory(prefix="podman-composectl-test.", dir=self.tmp_root) as tmp:
            registry = Path(tmp) / "registry.json"
            registry.write_text(
                json.dumps(
                    {
                        "stack": {
                            "user": owner,
                            "uid": str(os.getuid()),
                            "serviceName": "stack",
                            "workingDir": "/srv/stack",
                            "expectedComposeServices": ["web"],
                            "autoStart": True,
                            "state": "running",
                        }
                    }
                ),
                encoding="utf-8",
            )
            state = Path(tmp) / "podman-state.json"
            state.write_text(
                json.dumps(
                    [
                        {
                            "State": "running",
                            "Health": "unhealthy",
                            "Labels": {
                                "com.docker.compose.project.working_dir": "/srv/stack",
                                "io.podman.compose.service": "web",
                            },
                            "Noise": "x" * (os.sysconf("SC_ARG_MAX") + 65_536),
                        }
                    ]
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """
                    registry="$1"
                    helper=/bin/true
                    source "$2"
                    require_runtime_dir() { :; }
                    getent() { printf '%s\n' 'test:x:1:1::/:/bin/sh'; }
                    run_as_owner() { cat "$TEST_CONTAINERS_PATH"; }
                    main expected-runtime "$3"
                    """,
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                    owner,
                ],
                cwd=self.repo_root,
                env={**os.environ, "TEST_CONTAINERS_PATH": str(state)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )

        self.assertEqual(
            ["unhealthy service=stack compose-service=web"],
            result.stdout.splitlines(),
        )
        self.assertNotIn("Argument list too long", result.stderr)

    def test_expected_runtime_reports_missing_terminal_and_health_states(self):
        owner = pwd.getpwuid(os.getuid()).pw_name
        with tempfile.TemporaryDirectory(prefix="podman-composectl-test.", dir=self.tmp_root) as tmp:
            registry = Path(tmp) / "registry.json"
            registry.write_text(
                json.dumps(
                    {
                        "stack": {
                            "user": owner,
                            "uid": str(os.getuid()),
                            "serviceName": "stack",
                            "workingDir": "/srv/stack",
                            "expectedComposeServices": [
                                "healthy",
                                "starting",
                                "unhealthy",
                                "exited",
                                "missing",
                            ],
                            "autoStart": True,
                            "state": "running",
                        }
                    }
                ),
                encoding="utf-8",
            )
            containers = [
                {
                    "State": "running",
                    "Health": "healthy",
                    "Labels": {
                        "com.docker.compose.project.working_dir": "/srv/stack",
                        "io.podman.compose.service": "healthy",
                    },
                },
                {
                    "State": "running",
                    "Health": "starting",
                    "Labels": {
                        "com.docker.compose.project.working_dir": "/srv/stack",
                        "io.podman.compose.service": "starting",
                    },
                },
                {
                    "State": "running",
                    "Health": "unhealthy",
                    "Labels": {
                        "com.docker.compose.project.working_dir": "/srv/stack",
                        "io.podman.compose.service": "unhealthy",
                    },
                },
                {
                    "State": "exited",
                    "Labels": {
                        "com.docker.compose.project.working_dir": "/srv/stack",
                        "io.podman.compose.service": "exited",
                    },
                },
            ]
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """
                    registry="$1"
                    helper=/bin/true
                    source "$2"
                    require_runtime_dir() { :; }
                    getent() { printf '%s\n' 'test:x:1:1::/:/bin/sh'; }
                    run_as_owner() { printf '%s\n' "$TEST_CONTAINERS_JSON"; }
                    main expected-runtime "$3"
                    """,
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                    owner,
                    str(os.getuid()),
                    tmp,
                ],
                cwd=self.repo_root,
                env={**os.environ, "TEST_CONTAINERS_JSON": json.dumps(containers)},
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )

        self.assertEqual(
            [
                "starting service=stack compose-service=starting",
                "unhealthy service=stack compose-service=unhealthy",
                "non-running service=stack compose-service=exited states=exited",
                "missing service=stack compose-service=missing",
            ],
            result.stdout.splitlines(),
        )

    def test_quadlet_actions_dispatch_directly_to_systemd(self):
        owner = pwd.getpwuid(os.getuid()).pw_name
        with tempfile.TemporaryDirectory(prefix="podman-composectl-test.", dir=self.tmp_root) as tmp:
            registry = Path(tmp) / "registry.json"
            registry.write_text(
                json.dumps(
                    {
                        "native": {
                            "backend": "quadlet",
                            "user": owner,
                            "uid": str(os.getuid()),
                            "unit": "native.service",
                            "serviceName": "native",
                        }
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """
                    registry="$1"
                    helper=/should/not/run
                    source "$2"
                    require_runtime_dir() { :; }
                    require_user_bus() { :; }
                    run_as_owner() {
                      shift 4
                      printf '%s\\n' "$*"
                    }
                    main native reload
                    main native link
                    main native clean
                    main native verify
                    main native repair
                    main native logs --since today
                    """,
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                ],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )

        self.assertEqual(
            [
                "systemctl --user restart native.service",
                "systemctl --user restart native.service",
                "systemctl --user stop native.service native-stage.service",
                "systemctl --user start native-verify.service",
                "systemctl --user reset-failed native.service native-verify.service native-*.service",
                "systemctl --user restart native.service",
                "journalctl --user --unit native.service --unit native-* --since today",
            ],
            result.stdout.splitlines(),
        )

    def test_missing_backend_preserves_compose_helper_dispatch(self):
        owner = pwd.getpwuid(os.getuid()).pw_name
        with tempfile.TemporaryDirectory(
            prefix="podman-composectl-test.", dir=self.tmp_root
        ) as tmp:
            registry = Path(tmp) / "registry.json"
            registry.write_text(
                json.dumps(
                    {
                        "legacy": {
                            "user": owner,
                            "uid": str(os.getuid()),
                            "unit": "legacy.service",
                            "serviceName": "legacy",
                            "metadataFile": "/metadata.json",
                        }
                    }
                ),
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    """
                    registry="$1"
                    helper=/compose-helper
                    source "$2"
                    require_runtime_dir() { :; }
                    run_as_owner() {
                      shift 4
                      printf '%s\\n' "$*"
                    }
                    main legacy link
                    main legacy clean
                    main legacy verify
                    main legacy repair
                    main legacy logs --tail 5
                    """,
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                ],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )

        prefix = (
            "env PATH=/run/wrappers/bin:/run/current-system/sw/bin "
            "NIX_PODMAN_COMPOSE_METADATA=/metadata.json "
            "NIX_PODMAN_COMPOSE_SERVICE_NAME=legacy /compose-helper"
        )
        self.assertEqual(
            [
                f"{prefix} link-files",
                f"{prefix} cleanup-files",
                f"{prefix} verify",
                f"{prefix} repair",
                f"{prefix} logs --tail 5",
            ],
            result.stdout.splitlines(),
        )


if __name__ == "__main__":
    unittest.main()
