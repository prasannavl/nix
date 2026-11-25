import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "export.py"
spec = importlib.util.spec_from_file_location("cloudflare_export", SCRIPT)
export = importlib.util.module_from_spec(spec)
spec.loader.exec_module(export)


class ExportChannelsTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        # All inputs are benign fixtures. No command invokes age, Nix or an API.
        self.start_patch(export, "REPO_ROOT", self.root)
        directory = self.root / "data/secrets/globals/tf/cloudflare"
        self.start_patch(export, "TF_CLOUDFLARE_ROOT", directory)
        self.source = directory / "access/account.tfvars"
        self.target = self.source.with_suffix(".tfvars.age")
        self.name = str(self.target.relative_to(self.root))
        self.policy = self.start_patch(subprocess, "check_output")
        self.encrypt = self.start_patch(subprocess, "run")

    def start_patch(self, obj, name, *args):
        p = patch.object(obj, name, *args)
        self.addCleanup(p.stop)
        return p.start()

    def channels(self):
        self.policy.return_value = json.dumps({self.name: ["fixture-recipient"]})
        return export.export_channels("access")

    def test_split_layout_is_refused_even_with_legacy_policy(self):
        split = export.TF_CLOUDFLARE_ROOT.parent / "cloudflare-platform"
        split.mkdir(parents=True)
        self.policy.return_value = json.dumps({self.name: ["fixture-recipient"]})
        for mode in ("all", "access", "tunnels"):
            with self.subTest(mode=mode), patch("sys.argv", ["export.py", "--only", mode]), \
                 patch.object(export, "resolve_api_token") as token:
                with self.assertRaisesRegex(SystemExit, "Split project tfvars"):
                    export.main()
                token.assert_not_called()
        self.policy.assert_not_called()
        self.encrypt.assert_not_called()
        self.assertFalse(export.TF_CLOUDFLARE_ROOT.exists())

    def test_refusal_precedes_credentials_and_export(self):
        for mode in ("access", "tunnels", "all"):
            for policy in ({}, {self.name: []}, {"cloudflare-platform/access-account": ["fixture"]}):
                with self.subTest(mode=mode, policy=policy):
                    self.policy.return_value = json.dumps(policy)
                    with patch("sys.argv", ["export.py", "--only", mode]), \
                         patch.object(export, "resolve_account_id") as account, \
                         patch.object(export, "resolve_api_token") as token, \
                         patch.object(export, "export") as publish:
                        with self.assertRaisesRegex(SystemExit, "Unmanaged export channel"):
                            export.main()
                        account.assert_not_called()
                        token.assert_not_called()
                        publish.assert_not_called()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_publish_only_fresh_ciphertext(self):
        channels = self.channels()
        marker = b"age-encryption.org/v1\nsynthetic output"
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b"prior fixture")

        def fake_age(args, *, input, stdout, cwd, check):
            self.assertEqual(args, ["age", "--encrypt", "-r", "fixture-recipient"])
            self.assertEqual(input, b'example = "fixture"\n')
            self.assertEqual(cwd, self.root)
            self.assertTrue(check)
            self.assertFalse(self.source.exists())
            stdout.write(marker)

        self.encrypt.side_effect = fake_age
        self.assertEqual(export.write_secret_tfvars(channels, self.source, {"example": "fixture"}), self.target)
        self.assertEqual(self.target.read_bytes(), marker)
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_noop_and_failed_encryptor_do_not_publish_or_destroy(self):
        channels = self.channels()
        for stale in (False, True):
            if stale:
                self.target.write_bytes(b"age-encryption.org/v1\nstale fixture")

            def header_only(*args, stdout, **kwargs):
                stdout.write(b"age-encryption.org/v1\n")

            def fail_after_output(*args, stdout, **kwargs):
                stdout.write(b"age-encryption.org/v1\npartial fixture")
                raise subprocess.CalledProcessError(1, ["fake-age"])

            for outcome in (None, header_only, fail_after_output):
                with self.subTest(stale=stale, outcome=outcome):
                    self.encrypt.side_effect = outcome
                    with self.assertRaises((RuntimeError, subprocess.CalledProcessError)):
                        export.write_secret_tfvars(channels, self.source, {"fixture": True})
                    if stale:
                        self.assertEqual(self.target.read_bytes(), b"age-encryption.org/v1\nstale fixture")
                    self.assertEqual(list(self.target.parent.iterdir()), [self.target] if stale else [])

    def test_preserves_existing_input_and_does_not_prune(self):
        channels = self.channels()
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b"prior fixture")
        self.assertIsNone(export.write_secret_tfvars(channels, self.source, {}))
        self.source.write_text("existing fixture")
        with self.assertRaisesRegex(ValueError, "existing plaintext"):
            export.write_secret_tfvars(channels, self.source, {"fixture": True})
        self.assertEqual(self.source.read_text(), "existing fixture")
        self.assertEqual(self.target.read_bytes(), b"prior fixture")
        self.encrypt.assert_not_called()


if __name__ == "__main__":
    unittest.main()
