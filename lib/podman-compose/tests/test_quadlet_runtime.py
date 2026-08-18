import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


class QuadletRuntimeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.repo_root = Path(__file__).resolve().parents[3]
        cls.helper = cls.repo_root / "lib/podman-compose/quadlet-helper.sh"
        cls.tmp_root = cls.repo_root / "tmp"
        cls.tmp_root.mkdir(exist_ok=True)

    def run_script(self, command, *args, check=True):
        return subprocess.run(
            ["bash", str(self.helper), command, *map(str, args)],
            cwd=self.repo_root,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=check,
        )

    def test_stage_actions_install_atomically_and_cleanup(self):
        with tempfile.TemporaryDirectory(prefix="quadlet-stage-test.", dir=self.tmp_root) as tmp:
            root = Path(tmp)
            working_dir = root / "runtime"
            generated_dir = working_dir / ".podman-compose"
            state = generated_dir / "state.json"

            self.run_script("stage", "init", working_dir)
            state.write_text("stale", encoding="utf-8")
            self.run_script("stage", "init", working_dir)
            self.assertTrue((generated_dir / "lifecycle.lock").is_file())
            self.assertFalse(state.exists())

            data_dir = working_dir / "data"
            self.run_script(
                "stage",
                "prepare-dir",
                data_dir,
                "0750",
                "-",
                "-",
                "host",
                "false",
            )
            self.run_script(
                "stage",
                "finalize-dir",
                data_dir,
                "0750",
                "-",
                "-",
                "host",
                "false",
            )
            self.assertEqual(0o750, stat.S_IMODE(data_dir.stat().st_mode))

            source = root / "source.txt"
            source.write_text("new contents\n", encoding="utf-8")
            destination = working_dir / "config/app.conf"
            destination.mkdir(parents=True)
            (destination / "stale").write_text("stale", encoding="utf-8")
            self.run_script(
                "stage",
                "stage-file",
                source,
                destination,
                "0640",
                "-",
                "-",
                "host",
            )
            self.assertEqual("new contents\n", destination.read_text(encoding="utf-8"))
            self.assertEqual(0o640, stat.S_IMODE(destination.stat().st_mode))
            self.assertFalse(Path(f"{destination}.tmp").exists())

            token = root / "token"
            certificate = root / "certificate"
            token.write_text("secret\n", encoding="utf-8")
            certificate.write_text("line1\nline2\n", encoding="utf-8")
            env_file = working_dir / "secrets/app.env"
            self.run_script(
                "stage",
                "stage-env",
                env_file,
                "0600",
                "-",
                "-",
                "host",
                f"TOKEN={token}",
                f"CERT={certificate}",
            )
            self.assertEqual("TOKEN=secret\nCERT=line1line2\n", env_file.read_text(encoding="utf-8"))
            self.assertEqual(0o600, stat.S_IMODE(env_file.stat().st_mode))

            self.run_script("stage", "cleanup", generated_dir, destination, env_file)
            self.assertFalse(destination.exists())
            self.assertFalse(env_file.exists())

            destination_tmp = Path(f"{destination}.tmp")
            env_file_tmp = Path(f"{env_file}.tmp")
            destination_tmp.write_text("partial config", encoding="utf-8")
            env_file_tmp.write_text("PARTIAL=secret\n", encoding="utf-8")
            self.run_script("stage", "cleanup", generated_dir, destination, env_file)
            self.assertFalse(destination_tmp.exists())
            self.assertFalse(env_file_tmp.exists())

    def test_once_directory_keeps_existing_permissions(self):
        with tempfile.TemporaryDirectory(prefix="quadlet-stage-once-test.", dir=self.tmp_root) as tmp:
            directory = Path(tmp) / "persistent"
            self.run_script(
                "stage",
                "prepare-dir",
                directory,
                "0750",
                "-",
                "-",
                "host",
                "true",
            )
            os.chmod(directory, 0o711)
            self.run_script(
                "stage",
                "prepare-dir",
                directory,
                "0750",
                "-",
                "-",
                "host",
                "true",
            )
            self.assertEqual(0o711, stat.S_IMODE(directory.stat().st_mode))

    def test_cleanup_rejects_root(self):
        result = self.run_script("stage", "cleanup", "/tmp/generated", "/", check=False)
        self.assertEqual(2, result.returncode)
        self.assertIn("refusing unsafe", result.stderr)

    def test_hooks_run_in_order_and_honor_ignored_failure(self):
        with tempfile.TemporaryDirectory(prefix="quadlet-hook-test.", dir=self.tmp_root) as tmp:
            working_dir = Path(tmp)
            commands = []
            for index, command in enumerate(
                ["printf first > order", "-false", "printf second >> order"]
            ):
                command_file = working_dir / f"command-{index}"
                command_file.write_text(command, encoding="utf-8")
                commands.append(command_file)
            result = self.run_script(
                "hook",
                "pre-start",
                working_dir,
                *commands,
            )
            self.assertEqual("firstsecond", (working_dir / "order").read_text(encoding="utf-8"))
            self.assertIn("ignoring", result.stdout)

    def test_hook_failure_stops_the_sequence(self):
        with tempfile.TemporaryDirectory(prefix="quadlet-hook-failure-test.", dir=self.tmp_root) as tmp:
            marker = Path(tmp) / "should-not-exist"
            failing_command = Path(tmp) / "failing-command"
            trailing_command = Path(tmp) / "trailing-command"
            failing_command.write_text("false", encoding="utf-8")
            trailing_command.write_text(f"touch {marker}", encoding="utf-8")
            result = self.run_script(
                "hook",
                "post-start",
                tmp,
                failing_command,
                trailing_command,
                check=False,
            )
            self.assertEqual(1, result.returncode)
            self.assertFalse(marker.exists())
            self.assertIn("post-start hook failed", result.stderr)

    def test_hook_missing_working_directory_falls_back_to_root(self):
        with tempfile.TemporaryDirectory(prefix="quadlet-hook-root-test.", dir=self.tmp_root) as tmp:
            command = Path(tmp) / "command"
            command.write_text('test "$(pwd)" = /', encoding="utf-8")
            self.run_script(
                "hook",
                "pre-stop",
                "/path/that/does/not/exist",
                command,
            )


if __name__ == "__main__":
    unittest.main()
