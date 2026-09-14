import importlib.util
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "report-ext-sources.py"
SPEC = importlib.util.spec_from_file_location("report_ext_sources", SCRIPT)
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


class ReportExtSourcesTests(unittest.TestCase):
    def test_load_packages_uses_sources_nix_entries(self):
        path = Path("pkgs/ext/example/sources.nix")
        sources = {
            "example": {
                "kind": "github-tags",
                "owner": "owner",
                "repo": "repo",
                "version": "1.2.3",
            }
        }

        with mock.patch.object(REPORT, "load_sources", return_value=sources):
            self.assertEqual(REPORT.load_packages([path]), [("example", sources["example"])])

    def test_load_packages_rejects_unknown_report_kind(self):
        path = Path("pkgs/ext/example/sources.nix")
        with mock.patch.object(
            REPORT,
            "load_sources",
            return_value={"example": {"kind": "custom", "version": "1.0"}},
        ):
            with self.assertRaisesRegex(RuntimeError, "unsupported report kind"):
                REPORT.load_packages([path])

    def test_report_marks_current_version_latest(self):
        source = {"kind": "github-tags", "version": "1.2.3"}
        with mock.patch.object(REPORT, "latest_value", return_value="1.2.3"):
            line, ok = REPORT.report_package("example", source, False)

        self.assertTrue(ok)
        self.assertEqual(line, "- example: 1.2.3 [latest]")

    def test_report_surfaces_lookup_failures(self):
        source = {"kind": "github-tags", "version": "1.2.3"}
        with mock.patch.object(REPORT, "latest_value", side_effect=RuntimeError("offline")):
            line, ok = REPORT.report_package("example", source, False)

        self.assertFalse(ok)
        self.assertEqual(line, "- example: 1.2.3 [check failed: offline]")

    def test_latest_tag_preserves_version_shape(self):
        self.assertEqual(
            REPORT.latest_comparable_tag("1.2.3", ["1.3", "1.2.4", "2.0.0-beta"]),
            "1.2.4",
        )


if __name__ == "__main__":
    unittest.main()
