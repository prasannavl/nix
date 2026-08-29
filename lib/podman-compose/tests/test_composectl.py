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
        with tempfile.TemporaryDirectory(
            prefix="podman-composectl-test.", dir=self.tmp_root
        ) as tmp:
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
                    'registry="$1" helper=/bin/true; source "$2"; main expected-units alice',
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

    def test_restart_managed_waits_for_final_state_before_selecting_units(self):
        with tempfile.TemporaryDirectory(
            prefix="podman-composectl-test.", dir=self.tmp_root
        ) as tmp:
            registry = Path(tmp) / "registry.json"
            state_dir = Path(tmp) / "states"
            state_dir.mkdir()
            registry.write_text(
                json.dumps(
                    {
                        "alice-auto": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-auto.service",
                            "autoStart": True,
                            "state": "running",
                        },
                        "alice-active": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-active.service",
                            "autoStart": False,
                            "state": "running",
                        },
                        "alice-activating": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-activating.service",
                            "autoStart": False,
                            "state": "running",
                        },
                        "alice-failed": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-failed.service",
                            "autoStart": False,
                            "state": "running",
                        },
                        "alice-inactive": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-inactive.service",
                            "autoStart": False,
                            "state": "running",
                        },
                        "alice-deactivating": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-deactivating.service",
                            "autoStart": False,
                            "state": "running",
                        },
                        "alice-maintenance": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-maintenance.service",
                            "autoStart": False,
                            "state": "running",
                        },
                        "alice-masked": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-masked.service",
                            "autoStart": False,
                            "state": "running",
                        },
                        "alice-queued": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-queued.service",
                            "autoStart": False,
                            "state": "running",
                        },
                        "alice-race": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-race.service",
                            "autoStart": False,
                            "state": "running",
                        },
                        "alice-refreshing": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-refreshing.service",
                            "autoStart": False,
                            "state": "running",
                        },
                        "alice-reloading": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-reloading.service",
                            "autoStart": False,
                            "state": "running",
                        },
                        "alice-stopped": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-stopped.service",
                            "autoStart": True,
                            "state": "stopped",
                        },
                        "alice-stop-race": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-stop-race.service",
                            "autoStart": False,
                            "state": "running",
                        },
                        "bob-web": {
                            "user": "bob",
                            "uid": "1002",
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
                    """
                    registry="$1"
                    helper=/bin/true
                    state_dir="$3"
                    NIX_PODMAN_COMPOSE_RESTART_SETTLE_TIMEOUT_SECONDS=08
                    source "$2"
                    user_bus_available() { return 0; }
                    sleep() { :; }
                    run_as_owner() {
                      owner="$1"
                      shift 4
                      if [ "$1 $2 $3" = 'systemctl --user restart' ] || [ "$1 $2 $3" = 'systemctl --user try-restart' ]; then
                        if [ "$1 $2 $3" = 'systemctl --user restart' ]; then
                          for restarted_unit in "${@:4}"; do
                            : >"$state_dir/$restarted_unit.restarted"
                          done
                        fi
                        printf '%s:%s\n' "$owner" "$*"
                        return
                      fi
                      [ "$1 $2 $3" = 'systemctl --user show' ] || return 64
                      unit="${!#}"
                      counter_file="$state_dir/$unit"
                      count=0
                      [ ! -f "$counter_file" ] || read -r count <"$counter_file"
                      printf '%s\n' "$((count + 1))" >"$counter_file"
                      case "$unit:$count" in
                        alice-active.service:* | alice-activating.service:[1-9]* | alice-queued.service:[1-9]* | alice-refreshing.service:[1-9]* | alice-reloading.service:[1-9]* | alice-race.service:0 | alice-stop-race.service:0)
                          printf 'LoadState=loaded\nActiveState=active\nJob=\n'
                          ;;
                        alice-failed.service:* | alice-maintenance.service:1)
                          printf 'LoadState=loaded\nActiveState=failed\nJob=\n'
                          ;;
                        alice-inactive.service:* | alice-deactivating.service:1 | alice-stop-race.service:[1-9]*)
                          printf 'LoadState=loaded\nActiveState=inactive\nJob=\n'
                          ;;
                        alice-masked.service:*)
                          printf 'LoadState=masked\nActiveState=inactive\nJob=\n'
                          ;;
                        alice-race.service:[1-9]*)
                          if [ -f "$state_dir/$unit.restarted" ]; then
                            printf 'LoadState=loaded\nActiveState=active\nJob=\n'
                          else
                            printf 'LoadState=loaded\nActiveState=failed\nJob=\n'
                          fi
                          ;;
                        alice-activating.service:0)
                          printf 'LoadState=loaded\nActiveState=activating\nJob=101\n'
                          ;;
                        alice-deactivating.service:0)
                          printf 'LoadState=loaded\nActiveState=deactivating\nJob=102\n'
                          ;;
                        alice-maintenance.service:0)
                          printf 'LoadState=loaded\nActiveState=maintenance\nJob=\n'
                          ;;
                        alice-queued.service:0)
                          printf 'LoadState=loaded\nActiveState=inactive\nJob=103\n'
                          ;;
                        alice-refreshing.service:0)
                          printf 'LoadState=loaded\nActiveState=refreshing\nJob=104\n'
                          ;;
                        alice-reloading.service:0)
                          printf 'LoadState=loaded\nActiveState=reloading\nJob=105\n'
                          ;;
                        *) return 65 ;;
                      esac
                    }
                    main restart-managed alice
                    """,
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                    str(state_dir),
                ],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
            )

        self.assertEqual(
            [
                "alice:systemctl --user try-restart alice-activating.service alice-active.service alice-queued.service alice-race.service alice-refreshing.service alice-reloading.service alice-stop-race.service",
                "alice:systemctl --user restart alice-auto.service alice-failed.service alice-maintenance.service alice-race.service",
            ],
            result.stdout.splitlines(),
        )
        self.assertIn(
            "[managed-restart] user=alice unit=alice-deactivating.service settled state=inactive",
            result.stderr,
        )
        self.assertIn(
            '[managed-restart] user=alice action=try-restarting count=7 units="alice-activating.service, alice-active.service, alice-queued.service, alice-race.service, alice-refreshing.service, alice-reloading.service, alice-stop-race.service"',
            result.stderr,
        )
        self.assertIn(
            '[managed-restart] user=alice action=restarting count=4 units="alice-auto.service, alice-failed.service, alice-maintenance.service, alice-race.service"',
            result.stderr,
        )
        self.assertIn(
            "[managed-restart] user=alice unit=alice-stop-race.service preserved state=inactive after restart convergence",
            result.stderr,
        )

    def test_restart_managed_fails_if_later_restart_leaves_manual_unit_failed(self):
        with tempfile.TemporaryDirectory(
            prefix="podman-composectl-test.", dir=self.tmp_root
        ) as tmp:
            registry = Path(tmp) / "registry.json"
            counter = Path(tmp) / "manual-shows"
            registry.write_text(
                json.dumps(
                    {
                        "alice-auto": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-auto.service",
                            "autoStart": True,
                            "state": "running",
                        },
                        "alice-manual": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-manual.service",
                            "autoStart": False,
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
                    """
                    registry="$1"
                    helper=/bin/true
                    counter="$3"
                    source "$2"
                    user_bus_available() { return 0; }
                    run_as_owner() {
                      owner="$1"
                      shift 4
                      case "$1 $2 $3" in
                        'systemctl --user try-restart' | 'systemctl --user restart')
                          printf '%s:%s\n' "$owner" "$*"
                          ;;
                        'systemctl --user show')
                          count=0
                          [ ! -f "$counter" ] || read -r count <"$counter"
                          printf '%s\n' "$((count + 1))" >"$counter"
                          if [ "$count" -lt 2 ]; then
                            printf 'LoadState=loaded\nActiveState=active\nJob=\n'
                          else
                            printf 'LoadState=loaded\nActiveState=failed\nJob=\n'
                          fi
                          ;;
                        *) return 64 ;;
                      esac
                    }
                    main restart-managed alice
                    """,
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                    str(counter),
                ],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

        self.assertNotEqual(0, result.returncode)
        self.assertEqual(
            [
                "alice:systemctl --user try-restart alice-manual.service",
                "alice:systemctl --user restart alice-auto.service",
            ],
            result.stdout.splitlines(),
        )
        self.assertIn(
            "podman-composectl: managed unit alice-manual.service failed after restart convergence",
            result.stderr,
        )

    def test_restart_managed_fails_before_restart_when_state_does_not_settle(self):
        with tempfile.TemporaryDirectory(
            prefix="podman-composectl-test.", dir=self.tmp_root
        ) as tmp:
            registry = Path(tmp) / "registry.json"
            registry.write_text(
                json.dumps(
                    {
                        "alice-waiting": {
                            "user": "alice",
                            "uid": "1001",
                            "unit": "alice-waiting.service",
                            "autoStart": False,
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
                    NIX_PODMAN_COMPOSE_RESTART_SETTLE_TIMEOUT_SECONDS=0
                    source "$2"
                    user_bus_available() { return 0; }
                    run_as_owner() {
                      shift 4
                      if [ "$1 $2 $3" = 'systemctl --user restart' ]; then
                        printf 'unexpected restart: %s\n' "$*"
                        return
                      fi
                      printf 'LoadState=loaded\nActiveState=activating\nJob=201\n'
                    }
                    main restart-managed alice
                    """,
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                ],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

        self.assertNotEqual(0, result.returncode)
        self.assertEqual([], result.stdout.splitlines())
        self.assertIn(
            "podman-composectl: timed out waiting for managed unit alice-waiting.service to settle",
            result.stderr,
        )

    def test_restart_managed_fails_closed_on_invalid_runtime_state(self):
        cases = {
            "not-loaded": (
                "LoadState=not-found\nActiveState=inactive\nJob=\n",
                "managed unit alice-manual.service is not loaded: not-found",
            ),
            "incomplete": (
                "LoadState=loaded\nActiveState=active\n",
                "incomplete runtime state for managed unit alice-manual.service",
            ),
            "unknown": (
                "LoadState=loaded\nActiveState=dead\nJob=\n",
                "unexpected runtime state for managed unit alice-manual.service: dead",
            ),
        }
        for case, (runtime_state, expected_error) in cases.items():
            with (
                self.subTest(case=case),
                tempfile.TemporaryDirectory(
                    prefix="podman-composectl-test.", dir=self.tmp_root
                ) as tmp,
            ):
                registry = Path(tmp) / "registry.json"
                registry.write_text(
                    json.dumps(
                        {
                            "alice-manual": {
                                "user": "alice",
                                "uid": "1001",
                                "unit": "alice-manual.service",
                                "autoStart": False,
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
                        runtime_state="$3"
                        source "$2"
                        user_bus_available() { return 0; }
                        run_as_owner() { printf '%s' "$runtime_state"; }
                        main restart-managed alice
                        """,
                        "podman-composectl-test",
                        str(registry),
                        str(self.script),
                        runtime_state,
                    ],
                    cwd=self.repo_root,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )

                self.assertNotEqual(0, result.returncode)
                self.assertEqual([], result.stdout.splitlines())
                self.assertIn(expected_error, result.stderr)

    def test_restart_managed_fails_closed_on_invalid_registry(self):
        with tempfile.TemporaryDirectory(
            prefix="podman-composectl-test.", dir=self.tmp_root
        ) as tmp:
            registry = Path(tmp) / "registry.json"
            registry.write_text("not-json\n", encoding="utf-8")
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    'registry="$1" helper=/bin/true; source "$2"; main restart-managed',
                    "podman-composectl-test",
                    str(registry),
                    str(self.script),
                ],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

        self.assertNotEqual(0, result.returncode)
        self.assertIn("unable to read control registry", result.stderr)

    def test_expected_runtime_delegates_quadlet_verification_to_systemd(self):
        owner = pwd.getpwuid(os.getuid()).pw_name
        expected_labels = {
            "io.abird.podman-compose.backend": "quadlet",
            "io.abird.podman-compose.instance": "native",
            "io.abird.podman-compose.service": "web",
        }
        with tempfile.TemporaryDirectory(
            prefix="podman-composectl-test.", dir=self.tmp_root
        ) as tmp:
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
        with tempfile.TemporaryDirectory(
            prefix="podman-composectl-test.", dir=self.tmp_root
        ) as tmp:
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
                      query_uid="$2"
                      shift 4
                      case "$*" in
                        *' list-dependencies '*)
                          printf '%s\\n' \
                            native-stage.service \
                            native-web-container.service \
                            native-image-deadbeef-image.service \
                            native-verify.service \
                            podman-user-wait-network-online.service
                          ;;
                        *' show --property=SourcePath --value native-web-container.service')
                          printf '/etc/containers/systemd/users/%s/native-web.container\\n' "$query_uid"
                          ;;
                        *' show --property=SourcePath --value native-image-deadbeef-image.service')
                          printf '/etc/containers/systemd/users/%s/native-image.image\\n' "$query_uid"
                          ;;
                        *' show --property=SourcePath --value native-verify.service')
                          printf '\\n'
                          ;;
                        *) return 64 ;;
                      esac
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
        with tempfile.TemporaryDirectory(
            prefix="podman-composectl-test.", dir=self.tmp_root
        ) as tmp:
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
        with tempfile.TemporaryDirectory(
            prefix="podman-composectl-test.", dir=self.tmp_root
        ) as tmp:
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
                      query_uid="$2"
                      shift 4
                      case "$*" in
                        *' is-active --quiet native.service') return 0 ;;
                        *' start native-ready.target') return 0 ;;
                        *' list-dependencies '*)
                          printf '%s\n' \
                            native-stage.service \
                            native-web-container.service \
                            native-verify.service
                          ;;
                        *' show --property=SourcePath --value native-web-container.service')
                          printf '/etc/containers/systemd/users/%s/native-web.container\n' "$query_uid"
                          ;;
                        *' show --property=SourcePath --value native-verify.service') printf '\n' ;;
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
        with tempfile.TemporaryDirectory(
            prefix="podman-composectl-test.", dir=self.tmp_root
        ) as tmp:
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
        with tempfile.TemporaryDirectory(
            prefix="podman-composectl-test.", dir=self.tmp_root
        ) as tmp:
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
        with tempfile.TemporaryDirectory(
            prefix="podman-composectl-test.", dir=self.tmp_root
        ) as tmp:
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
