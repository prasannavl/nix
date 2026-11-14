import importlib.util
import json
import os
import secrets
import stat
import tempfile
import unittest
from pathlib import Path


spec = importlib.util.spec_from_file_location("runtime", os.environ["AI_RUNTIME_HELPERS"])
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class RuntimeTests(unittest.TestCase):
    def test_pairing_rotation_removal_and_private_atomic_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            key = root / "key"
            key.write_text(secrets.token_urlsafe(32))
            key.chmod(0o600)
            first = key.read_text()
            destination = root / "config.json"
            routes = [
                {"baseUrl": "https://one.test/v1", "model": "same", "key": first},
                {"baseUrl": "https://two.test/v1", "model": "same", "key": "independent"},
            ]
            routes[0]["key"] = runtime.read_credential(key)
            runtime.write_private_json(destination, routes)
            self.assertEqual(json.loads(destination.read_text()), routes)
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
            key.write_text(secrets.token_urlsafe(32) + "\n")
            routes[0]["key"] = runtime.read_credential(key)
            self.assertNotEqual(routes[0]["key"], first)
            runtime.write_private_json(destination, list(reversed(routes)))
            self.assertEqual(json.loads(destination.read_text()), list(reversed(routes)))
            key.unlink()
            with self.assertRaisesRegex(RuntimeError, "credential unavailable"):
                runtime.read_credential(key)
            runtime.write_private_json(destination, routes[1:])
            self.assertNotIn(first, destination.read_text())
            self.assertEqual(list(root.glob(".inference-*")), [])

    def test_invalid_keys_and_modes_have_safe_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "key"
            for payload in (b"", b"secret\ninjected", b"secret\x00", b"x" * 8193, b"\xff"):
                key.write_bytes(payload)
                key.chmod(0o600)
                with self.assertRaises(RuntimeError) as error:
                    runtime.read_credential(key)
                self.assertEqual(str(error.exception), "inference credential unavailable or invalid")
            key.write_text(secrets.token_urlsafe(32))
            key.chmod(0o644)
            with self.assertRaises(RuntimeError):
                runtime.read_credential(key)
            key.unlink()
            os.mkfifo(key, 0o600)
            with self.assertRaises(RuntimeError):
                runtime.read_credential(key)

    def test_failed_publish_preserves_private_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / "config.json"
            runtime.write_private_json(destination, {"old": True})
            with self.assertRaises(RuntimeError):
                runtime.write_private_json(destination, {"large": "x" * 65536})
            self.assertEqual(json.loads(destination.read_text()), {"old": True})
            root.chmod(0o755)
            with self.assertRaises(RuntimeError):
                runtime.write_private_json(destination, {})
            root.chmod(0o700)


if __name__ == "__main__":
    unittest.main()
