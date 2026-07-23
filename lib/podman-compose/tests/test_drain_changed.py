import json
import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


class PodmanComposeDrainChangedTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[3]
        cls.script = cls.repo_root / "lib/podman-compose/drain-changed.sh"

    def setUp(self):
        self.work_dir = Path(
            tempfile.mkdtemp(
                prefix="podman-compose-drain-test.", dir=self.repo_root / "tmp"
            )
        )
        self.fake_bin = self.work_dir / "bin"
        self.fake_bin.mkdir()
        self.history = self.work_dir / "history"
        self.old_registry = self.work_dir / "old.json"
        self.new_registry = self.work_dir / "new.json"
        self._write_fake_commands()

    def tearDown(self):
        shutil.rmtree(self.work_dir)

    def _write_executable(self, name: str, body: str):
        path = self.fake_bin / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def _write_fake_commands(self):
        bash = shutil.which("bash")
        self._write_executable(
            "setpriv",
            textwrap.dedent(
                f"""\
                #!{bash}
                while [ "$#" -gt 0 ] && [ "$1" != env ]; do shift; done
                exec "$@"
                """
            ),
        )
        self._write_executable(
            "systemctl",
            textwrap.dedent(
                f"""\
                #!{bash}
                if [ "$1" = is-active ]; then exit 0; fi
                if [ "$1" = --user ] && [ "$2" = show ]; then
                  printf '%s\n' active
                  exit 0
                fi
                if [ "$1" = --user ] && [ "$2" = stop ]; then
                  printf '%s\n' "$3" >>"$TEST_DRAIN_HISTORY"
                  [ "$3" != "${{TEST_DRAIN_FAIL_UNIT:-}}" ]
                  exit
                fi
                exit 64
                """
            ),
        )
        self._write_executable(
            "id",
            textwrap.dedent(
                f"""\
                #!{bash}
                if [ "$1" = -g ]; then printf '%s\n' 1234; exit 0; fi
                exit 64
                """
            ),
        )

    @staticmethod
    def entry(stamp=None, *, removal_policy="stop"):
        value = {
            "user": "demo",
            "uid": "1234",
            "unit": "",
            "removalPolicy": removal_policy,
        }
        if stamp is not None:
            value["drainStamp"] = stamp
        return value

    def write_registry(self, path: Path, entries):
        rendered = {}
        for name, value in entries.items():
            rendered[name] = value | {"unit": f"{name}.service"}
        path.write_text(json.dumps(rendered), encoding="utf-8")

    def run_script(self, *, fail_unit=None):
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.fake_bin}:{env['PATH']}",
                "NIX_PODMAN_COMPOSE_OLD_CONTROL_REGISTRY": str(self.old_registry),
                "NIX_PODMAN_COMPOSE_NEW_CONTROL_REGISTRY": str(self.new_registry),
                "TEST_DRAIN_HISTORY": str(self.history),
            }
        )
        if fail_unit is not None:
            env["TEST_DRAIN_FAIL_UNIT"] = fail_unit
        return subprocess.run(
            ["bash", str(self.script)],
            cwd=self.repo_root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    def drained_units(self):
        if not self.history.exists():
            return []
        return self.history.read_text(encoding="utf-8").splitlines()

    def test_only_changed_unit_is_drained(self):
        self.write_registry(
            self.old_registry,
            {"alpha": self.entry("same"), "beta": self.entry("old")},
        )
        self.write_registry(
            self.new_registry,
            {"alpha": self.entry("same"), "beta": self.entry("new")},
        )

        result = self.run_script()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["beta.service"], self.drained_units())

    def test_legacy_registry_without_stamps_is_drained_once(self):
        self.write_registry(
            self.old_registry,
            {"alpha": self.entry(), "beta": self.entry()},
        )
        self.write_registry(
            self.new_registry,
            {"alpha": self.entry("new-a"), "beta": self.entry("new-b")},
        )

        result = self.run_script()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(["alpha.service", "beta.service"], self.drained_units())

    def test_first_failure_leaves_later_units_untouched(self):
        self.write_registry(
            self.old_registry,
            {name: self.entry("old") for name in ("alpha", "beta", "gamma")},
        )
        self.write_registry(
            self.new_registry,
            {name: self.entry("new") for name in ("alpha", "beta", "gamma")},
        )

        result = self.run_script(fail_unit="beta.service")

        self.assertNotEqual(0, result.returncode)
        self.assertEqual(["alpha.service", "beta.service"], self.drained_units())
        self.assertIn("later units were left untouched", result.stderr)

    def test_removed_keep_unit_is_not_drained(self):
        self.write_registry(
            self.old_registry,
            {"manual": self.entry("old", removal_policy="keep")},
        )
        self.write_registry(self.new_registry, {})

        result = self.run_script()

        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], self.drained_units())


if __name__ == "__main__":
    unittest.main()
