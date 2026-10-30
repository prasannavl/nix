"""Synthetic helper contracts: no real container, network or persistent app state."""

import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(
    os.environ.get(
        "EXCALIDASH_TEST_HELPER", Path(__file__).resolve().parents[1] / "helper.sh"
    )
)


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="excalidash-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.data = self.root / "data"
        self.env_file = self.data / "backend.env"
        self.log = self.root / "commands.jsonl"
        stub = f"#!{sys.executable}\n" + """import json, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
with open(os.environ['TEST_COMMAND_LOG'], 'a') as log:
    log.write(json.dumps([name, *sys.argv[1:]]) + '\\n')
if name == 'openssl':
    status = int(os.environ.get('TEST_OPENSSL_STATUS', '0'))
    if not status and not os.environ.get('TEST_OPENSSL_EMPTY'):
        print('synthetic-fixture-' + sys.argv[-1])
else:
    status = int(os.environ.get('TEST_PODMAN_STATUS', '0'))
sys.exit(status)
"""
        for name in ["openssl", "podman"]:
            path = self.bin / name
            path.write_text(stub)
            path.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "EXCALIDASH_BACKEND_DATA_DIR": str(self.data / "backend"),
            "EXCALIDASH_BACKEND_IMAGE": "example.invalid/excalidash:fixture",
            "EXCALIDASH_DATABASE_PROVIDER": "sqlite",
            "EXCALIDASH_DATABASE_URL": "file:/app/prisma/dev.db",
            "EXCALIDASH_DATA_DIR": str(self.data),
            "EXCALIDASH_ENV_FILE": str(self.env_file),
            "EXCALIDASH_HELPER_PATH": str(HELPER),
            "EXCALIDASH_MIGRATION_LOCK_FILE": str(self.data / "migration.lock"),
            "TEST_COMMAND_LOG": str(self.log),
        }

    def run_helper(self, command, **extra):
        return subprocess.run(
            ["sh", str(HELPER), command], env={**self.env, **extra},
            capture_output=True, text=True, timeout=15,
        )

    def commands(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def ready_env(self, text="JWT_SECRET=fixture-jwt\nCSRF_SECRET=fixture-csrf\n"):
        self.data.mkdir(exist_ok=True)
        self.env_file.write_text(text)

    def test_migration_runs_as_container_root_with_no_network(self):
        self.ready_env()
        result = self.run_helper("migrate")
        self.assertEqual(result.returncode, 0, result.stderr)
        [command] = self.commands()
        self.assertEqual(command[:3], ["podman", "run", "--rm"])
        self.assertIn("--user", command)
        self.assertEqual(command[command.index("--user") + 1], "0")
        self.assertEqual(command[command.index("--network") + 1], "none")
        self.assertNotIn("--privileged", command)
        self.assertEqual(command[command.index("--env-file") + 1], str(self.env_file))
        self.assertIn(f"{HELPER}:/usr/local/bin/excalidash-helper.sh:ro", command)
        self.assertEqual(command[-3:], [
            "example.invalid/excalidash:fixture",
            "/usr/local/bin/excalidash-helper.sh",
            "container-migrate",
        ])
        self.assertTrue((self.data / "migration.lock").is_file())

    def test_provider_and_database_url_are_forwarded(self):
        self.ready_env()
        url = "postgresql://fixture@example.invalid/test"
        result = self.run_helper(
            "migrate", EXCALIDASH_DATABASE_PROVIDER="postgresql",
            EXCALIDASH_DATABASE_URL=url,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        [command] = self.commands()
        self.assertIn("DATABASE_PROVIDER=postgresql", command)
        self.assertIn(f"DATABASE_URL={url}", command)

    def test_missing_env_fails_before_container(self):
        result = self.run_helper("migrate")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("env file is missing", result.stderr)
        self.assertEqual(self.commands(), [])

    def test_container_failure_is_preserved(self):
        self.ready_env()
        result = self.run_helper("migrate", TEST_PODMAN_STATUS="47")
        self.assertEqual(result.returncode, 47, result.stderr)

    def test_prepare_env_is_private_and_idempotent(self):
        result = self.run_helper("prepare-env")
        self.assertEqual(result.returncode, 0, result.stderr)
        before = self.env_file.read_bytes()
        self.assertEqual(stat.S_IMODE(self.env_file.stat().st_mode), 0o600)
        self.assertIn(b"JWT_SECRET=synthetic-fixture-48\n", before)
        self.assertIn(b"CSRF_SECRET=synthetic-fixture-32\n", before)
        result = self.run_helper("prepare-env")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.env_file.read_bytes(), before)
        self.assertEqual(len(self.commands()), 2)

    def test_bootstrap_stops_on_random_generation_failure(self):
        result = self.run_helper("bootstrap", TEST_OPENSSL_STATUS="41")
        self.assertEqual(result.returncode, 41, result.stderr)
        self.assertEqual(self.env_file.read_bytes(), b"")
        self.assertFalse(any(command[0] == "podman" for command in self.commands()))

    def test_empty_generated_secret_is_not_persisted(self):
        result = self.run_helper("bootstrap", TEST_OPENSSL_EMPTY="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("generated secret is empty", result.stderr)
        self.assertEqual(self.env_file.read_bytes(), b"")
        self.assertFalse(any(command[0] == "podman" for command in self.commands()))

    def test_existing_empty_secret_fails_without_rotation(self):
        self.ready_env("JWT_SECRET=\nCSRF_SECRET=fixture-csrf\n")
        before = self.env_file.read_bytes()
        result = self.run_helper("bootstrap")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("existing secret is empty", result.stderr)
        self.assertEqual(self.env_file.read_bytes(), before)
        self.assertEqual(self.commands(), [])


if __name__ == "__main__":
    unittest.main()
