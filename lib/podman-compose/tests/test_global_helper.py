import json
import os
import pwd
import subprocess
import tempfile
import unittest
from pathlib import Path


class PodmanGlobalHelperTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[3]
        helper = cls.repo_root / "lib/podman-compose/helper.sh"
        cls.helper_definitions = helper.read_text(encoding="utf-8").rsplit('main "$@"', 1)[0]
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def run_reconcile(self, idmap_count, migrate_status=0, stop_status=0):
        with tempfile.TemporaryDirectory(prefix="podman-global-helper-test.", dir=self.tmp_root) as tmp:
            events = Path(tmp) / "events"
            script = f"""
{self.helper_definitions}
configure_rootless_storage() {{ :; }}
has_subid_range() {{ return 0; }}
rootless_idmap_matches_declared_ranges() {{ [[ {idmap_count} -gt 1 ]]; }}
podman() {{
    if [[ $1 == info ]]; then
        printf '%s\\n' '{{"host":{{"idMappings":{{"uidmap":[{','.join('{}' for _ in range(idmap_count))}],"gidmap":[{','.join('{}' for _ in range(idmap_count))}]}}}}}}'
        return 0
    fi
    printf '%s\\n' migrate >>"$events"
    return {migrate_status}
}}
systemctl() {{
    shift
    case "$1" in
    is-active) printf '%s\\n' is-active >>"$events"; return 0 ;;
    stop) printf '%s\\n' stop >>"$events"; return {stop_status} ;;
    start) printf '%s\\n' start >>"$events" ;;
    esac
}}
events="$1"
main rootless-idmap-reconcile tester /home/tester tester-managed.target
"""
            result = subprocess.run(
                ["bash", "-c", script, "podman-global-helper-test", str(events)],
                cwd=self.repo_root,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            recorded = events.read_text(encoding="utf-8").splitlines() if events.exists() else []
            return result, recorded

    def test_reconcile_is_noop_when_mapping_is_current(self):
        result, events = self.run_reconcile(idmap_count=2)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], events)
        self.assertIn("already active", result.stdout)

    def test_reconcile_cycles_managed_target_only_for_real_migration(self):
        result, events = self.run_reconcile(idmap_count=1)

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["is-active", "stop", "migrate", "start"], events)

    def test_reconcile_queues_recovery_after_failed_migration(self):
        result, events = self.run_reconcile(idmap_count=1, migrate_status=23)

        self.assertEqual(23, result.returncode)
        self.assertEqual(["is-active", "stop", "migrate", "start"], events)

    def test_reconcile_queues_recovery_after_failed_target_stop(self):
        result, events = self.run_reconcile(idmap_count=1, stop_status=24)

        self.assertEqual(24, result.returncode)
        self.assertEqual(["is-active", "stop", "start"], events)

    def test_mapping_comparison_covers_declared_range_identity(self):
        owner = pwd.getpwuid(os.getuid()).pw_name
        with tempfile.TemporaryDirectory(prefix="podman-global-helper-test.", dir=self.tmp_root) as tmp:
            root = Path(tmp)
            subuid = root / "subuid"
            subgid = root / "subgid"
            subuid.write_text(f"{owner}:200000:65536\n", encoding="utf-8")
            subgid.write_text(f"{owner}:300000:65536\n", encoding="utf-8")
            mapping = {
                "host": {
                    "idMappings": {
                        "uidmap": [
                            {"container_id": 0, "host_id": os.getuid(), "size": 1},
                            {"container_id": 1, "host_id": 200000, "size": 65536},
                        ],
                        "gidmap": [
                            {"container_id": 0, "host_id": os.getgid(), "size": 1},
                            {"container_id": 1, "host_id": 300000, "size": 65536},
                        ],
                    }
                }
            }
            command = f"""
{self.helper_definitions}
rootless_idmap_matches_declared_ranges "$1" "$2" "$3" "$4"
"""
            args = [
                "bash",
                "-c",
                command,
                "podman-global-helper-test",
                owner,
                json.dumps(mapping),
                str(subuid),
                str(subgid),
            ]

            matching = subprocess.run(args, cwd=self.repo_root, check=False)
            mapping["host"]["idMappings"]["uidmap"][1]["host_id"] += 1
            args[5] = json.dumps(mapping)
            changed = subprocess.run(args, cwd=self.repo_root, check=False)

        self.assertEqual(0, matching.returncode)
        self.assertNotEqual(0, changed.returncode)
