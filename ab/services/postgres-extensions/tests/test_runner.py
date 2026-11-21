import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("runner", ROOT / "runner.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)
POLICY = json.loads((ROOT / "release.json").read_text())


class FakeDatabase:
    def __init__(self):
        self.states = {
            "abird": {"timescaledb": "2.26.4", "timescaledb_toolkit": "1.22.0",
                      "vector": "0.8.2", "vectorscale": "0.9.0", "postgis": "3.6.3"},
            "postgres": {"timescaledb": "2.26.4", "timescaledb_toolkit": "1.22.0"},
            "template1": {"timescaledb": "2.26.4", "timescaledb_toolkit": "1.22.0"},
        }
        self.writes = []
        self.missing_path = None
        self.missing_target = False
        self.fail_write = None
        self.false_success = False
        self.major = 18
        self.image = POLICY["image"]
        self.locked = False

    @contextmanager
    def lock(self):
        self.locked = True
        try:
            yield
        finally:
            self.locked = False

    def check_image(self, image):
        if image != self.image:
            raise RuntimeError("wrong image")

    def query(self, db, sql):
        if "FROM pg_database" in sql:
            return sorted(self.states)
        if "'major'" in sql:
            return {"major": self.major, "installed": dict(self.states[db]),
                    "dependencies": [["vectorscale", "vector"]] if db == "abird" else []}
        name = next(n for n in POLICY["extensions"] if runner.literal(n) in sql)
        return {"available": not self.missing_target,
                "path": None if (db, name) == self.missing_path else "reviewed-path"}

    def sql(self, db, sql, readonly):
        assert not readonly and self.locked
        name = next(n for n in POLICY["extensions"] if runner.identifier(n) in sql)
        self.writes.append((db, name, sql))
        if (db, name) == self.fail_write:
            raise RuntimeError("injected SQL failure")
        if not self.false_success:
            self.states[db][name] = POLICY["extensions"][name]["target"]


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.database = FakeDatabase()
        self.output = patch("builtins.print")
        self.output.start()
        self.addCleanup(self.output.stop)

    def test_plan_is_readonly_and_covers_template_not_template0(self):
        steps = runner.migrate(self.database, POLICY, False)
        self.assertEqual({s["database"] for s in steps}, {"abird", "postgres", "template1"})
        self.assertEqual(self.database.writes, [])

    def test_target_only_policy_uses_catalog_version_and_update_path(self):
        policy = copy.deepcopy(POLICY)
        for rule in policy["extensions"].values():
            rule.pop("sources")
        runner.migrate(self.database, policy, True)
        self.assertEqual(len(self.database.writes), 9)
        self.database.writes.clear()
        runner.migrate(self.database, policy, True)
        self.assertEqual(self.database.writes, [])

    def test_apply_only_installed_in_dependency_order_and_rerun_noops(self):
        runner.migrate(self.database, POLICY, True)
        names = [name for db, name, _ in self.database.writes if db == "abird"]
        self.assertLess(names.index("vector"), names.index("vectorscale"))
        self.assertLess(names.index("timescaledb"), names.index("timescaledb_toolkit"))
        self.assertEqual(len(self.database.writes), 9)
        self.database.writes.clear()
        runner.migrate(self.database, POLICY, True)
        self.assertEqual(self.database.writes, [])

    def test_last_database_missing_path_blocks_all_writes(self):
        self.database.missing_path = ("template1", "timescaledb_toolkit")
        with self.assertRaisesRegex(RuntimeError, "missing target or update path"):
            runner.migrate(self.database, POLICY, True)
        self.assertEqual(self.database.writes, [])

    def test_unreviewed_newer_source_is_not_downgraded(self):
        self.database.states["abird"]["vector"] = "0.9.0"
        with self.assertRaisesRegex(RuntimeError, "downgrade prohibited"):
            runner.migrate(self.database, POLICY, True)
        self.assertEqual(self.database.writes, [])

    def test_optional_upgrade_from_restricts_catalog_source(self):
        policy = copy.deepcopy(POLICY)
        for rule in policy["extensions"].values():
            rule.pop("sources")
        policy["extensions"]["vector"]["upgradeFrom"] = ["0.8.1"]
        with self.assertRaisesRegex(RuntimeError, "not permitted by upgradeFrom"):
            runner.migrate(self.database, policy, True)
        self.assertEqual(self.database.writes, [])

    def test_unavailable_target_blocks_all_writes(self):
        self.database.missing_target = True
        with self.assertRaisesRegex(RuntimeError, "missing target or update path"):
            runner.migrate(self.database, POLICY, True)
        self.assertEqual(self.database.writes, [])

    def test_failure_stops_and_partial_run_resumes_from_catalog(self):
        self.database.fail_write = ("postgres", "timescaledb")
        with self.assertRaisesRegex(RuntimeError, "injected SQL failure"):
            runner.migrate(self.database, POLICY, True)
        self.assertFalse(any(db == "template1" for db, _, _ in self.database.writes))
        self.database.fail_write = None
        self.database.writes.clear()
        runner.migrate(self.database, POLICY, True)
        self.assertFalse(any(db == "abird" for db, _, _ in self.database.writes))

    def test_catalog_verification_rejects_false_success(self):
        self.database.false_success = True
        with self.assertRaisesRegex(RuntimeError, "completion verification failed"):
            runner.migrate(self.database, POLICY, True)
        self.assertEqual(len(self.database.writes), 1)

    def test_wrong_image_and_major_fail_before_writes(self):
        for attr, value in [("image", "other-image"), ("major", 19)]:
            db = FakeDatabase()
            setattr(db, attr, value)
            with self.assertRaises(RuntimeError):
                runner.migrate(db, POLICY, True)
            self.assertEqual(db.writes, [])

    def test_policy_rejects_invalid_name_and_upgrade_restrictions(self):
        for rules in [
            {"bad;sql": {"target": "1.2"}},
            {"vector": {"target": "0.8.6", "upgradeFrom": ["0.9.0"]}},
            {"vector": {"target": "0.8.6", "upgradeFrom": ["0.8.2", "0.8.1"]}},
            {"vector": {"target": "0.8.6", "upgradeFrom": []}},
            {"vector": {"target": "0.8.6", "sources": ["0.8.2"], "upgradeFrom": ["0.8.2"]}},
            {"vector": {"target": "0.8.6", "upgrade_from": ["0.8.2"]}},
        ]:
            policy = copy.deepcopy(POLICY)
            policy["extensions"] = rules
            with self.assertRaises(ValueError):
                runner.validate_policy(policy)

    def test_dependency_cycle_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "Cyclic"):
            runner.migration_order({"vector": "0.8.2", "vectorscale": "0.9.0"},
                                   [["vector", "vectorscale"], ["vectorscale", "vector"]], POLICY)

    def test_sql_quotes_and_fresh_psql_flags(self):
        self.assertEqual(runner.literal("x'y"), "'x''y'")
        self.assertEqual(runner.identifier('x"y'), '"x""y"')
        db = runner.Database(["podman"], "postgres", "postgres", 300)
        command = db.command("db name")
        self.assertIn("-X", command)
        self.assertIn("ON_ERROR_STOP=1", command)
        self.assertEqual(command[command.index("--dbname") + 1], "dbname='db name'")
        self.assertEqual(runner.connection_database("host=other db'"), "dbname='host=other db\\''")

    def test_transport_timeout_terminates_child_group(self):
        # A real wrapper that waits on a child mirrors the SSH relay ownership.
        with tempfile.TemporaryDirectory(dir=ROOT.parents[2] / "tmp") as directory:
            marker = Path(directory) / "survived"
            child = f"import time,pathlib; time.sleep(1.5); pathlib.Path({str(marker)!r}).touch()"
            wrapper = "import subprocess,sys; subprocess.run([sys.executable,'-c',sys.argv[1]])"
            with self.assertRaises(subprocess.TimeoutExpired):
                runner.run_command([sys.executable, "-c", wrapper, child], 1)
            # The child would write after timeout if only its parent was killed.
            subprocess.run([sys.executable, "-c", "import time;time.sleep(1)"], check=True)
            self.assertFalse(marker.exists())

    def test_guard_loss_terminates_inflight_transport(self):
        class LostGuard:
            def poll(self):
                return 1

        with self.assertRaisesRegex(RuntimeError, "lock connection was lost"):
            runner.run_command([sys.executable, "-c", "import time;time.sleep(10)"], 15, LostGuard())

    def test_interrupt_terminates_transport_children(self):
        class InterruptGuard:
            calls = 0

            def poll(self):
                self.calls += 1
                if self.calls > 1:
                    raise KeyboardInterrupt()
                return None

        with tempfile.TemporaryDirectory(dir=ROOT.parents[2] / "tmp") as directory:
            marker = Path(directory) / "survived"
            child = f"import time,pathlib; time.sleep(1); pathlib.Path({str(marker)!r}).touch()"
            wrapper = "import subprocess,sys; subprocess.run([sys.executable,'-c',sys.argv[1]])"
            with self.assertRaises(KeyboardInterrupt):
                runner.run_command([sys.executable, "-c", wrapper, child], 15, InterruptGuard())
            subprocess.run([sys.executable, "-c", "import time;time.sleep(1)"], check=True)
            self.assertFalse(marker.exists())

    def test_guard_wrapper_exit_still_cleans_surviving_child(self):
        with tempfile.TemporaryDirectory(dir=ROOT.parents[2] / "tmp") as directory:
            marker = Path(directory) / "survived"
            child = f"import time,pathlib; time.sleep(1); pathlib.Path({str(marker)!r}).touch()"
            wrapper = ("import subprocess,sys,os; subprocess.Popen([sys.executable,'-c',sys.argv[1]]); "
                       "print('[true,47]',flush=True); os._exit(0)")
            db = runner.Database(["unused"], "unused", "postgres", 300)
            with patch.object(db, "command", return_value=[sys.executable, "-c", wrapper, child]):
                with db.lock():
                    db.guard.wait(timeout=5)
            subprocess.run([sys.executable, "-c", "import time;time.sleep(1)"], check=True)
            self.assertFalse(marker.exists())
            self.assertIsNone(db.guard)

    def test_idle_transport_without_server_lock_cannot_write(self):
        db = runner.Database(["unused"], "unused", "postgres", 300)
        db.guard = unittest.mock.Mock()
        db.guard.poll.return_value = None
        db.guard_pid = 47
        with patch.object(db, "query", return_value=False), patch.object(runner, "run_command") as execute:
            with self.assertRaisesRegex(RuntimeError, "no longer owns the migration lock"):
                db.sql("app", "ALTER EXTENSION vector UPDATE TO '0.8.6';", False)
            execute.assert_not_called()


if __name__ == "__main__":
    unittest.main()
