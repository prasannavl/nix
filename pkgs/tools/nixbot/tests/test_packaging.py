"""Shared Bash entrypoint and Rust compatibility-name packaging contract."""

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[4]


class NixbotPackagingTests(unittest.TestCase):
    def test_bash_owns_the_nixbot_entrypoint(self):
        recipe = (ROOT / "pkgs/tools/nixbot/default.nix").read_text()
        self.assertIn("mkShellScriptDerivation", recipe)
        self.assertIn("${./nixbot.sh}", recipe)

    def test_manager_does_not_install_the_compatibility_entrypoint(self):
        recipe = (ROOT / "pkgs/tools/abird-host-manager/default.nix").read_text()
        self.assertIn('rm -f "$out/bin/nixbot"', recipe)


if __name__ == "__main__":
    unittest.main()
