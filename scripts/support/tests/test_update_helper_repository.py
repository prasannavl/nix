"""Retained wrappers agree with their own root inputs, without fixed repo values."""

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "update_helper_repository", ROOT / "scripts/support/update-helper.py"
)
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


class RepositoryWrapperTests(unittest.TestCase):
    def test_retained_wrapper_refs_match_their_root(self):
        urls = HELPER.root_urls(ROOT)
        for path in HELPER.discover_wrappers(ROOT):
            with self.subTest(wrapper=path.relative_to(ROOT)):
                text = path.read_text()
                self.assertEqual(HELPER.update_wrapper(text, urls), text)


if __name__ == "__main__":
    unittest.main()
