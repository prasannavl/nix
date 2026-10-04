import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "scripts/support/update-helper.py"
TMP_ROOT = REPO_ROOT / "tmp/helper-consolidation"
SPEC = importlib.util.spec_from_file_location("update_helper_cli", SCRIPT)
HELPER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HELPER)


class UpdateHelperCliTests(unittest.TestCase):
    def test_report_sources_dispatch_preserves_options_and_status(self):
        with mock.patch.object(HELPER, "report_sources", return_value=7) as report, \
                mock.patch.object(HELPER, "sync_child_refs") as refs:
            status = HELPER.main([
                "report-sources", "-j", "3", "--color", "never",
                "first/sources.nix", "second/sources.nix",
            ])
        self.assertEqual(status, 7)
        refs.assert_not_called()
        report.assert_called_once()
        args = report.call_args.args[0]
        self.assertEqual(args.sources, [Path("first/sources.nix"), Path("second/sources.nix")])
        self.assertEqual(args.jobs, 3)
        self.assertEqual(args.color, "never")

    def test_report_sources_defaults_are_retained(self):
        with mock.patch.object(HELPER, "report_sources", return_value=0) as report:
            self.assertEqual(HELPER.main(["report-sources", "sources.nix"]), 0)
        args = report.call_args.args[0]
        self.assertEqual(args.jobs, 16)
        self.assertEqual(args.color, "auto")
        self.assertFalse(args.ansi)

    def test_ansi_alias_overrides_color_never(self):
        with mock.patch.object(HELPER, "report_sources", return_value=0) as report:
            self.assertEqual(HELPER.main([
                "report-sources", "--ansi", "--color=never", "sources.nix",
            ]), 0)
        self.assertTrue(report.call_args.args[0].ansi)
        self.assertEqual(report.call_args.args[0].color, "always")

    def test_child_refs_dispatch_preserves_root_mode_and_status(self):
        for mode in ("check", "write"):
            with self.subTest(mode=mode), \
                    mock.patch.object(HELPER, "sync_child_refs", return_value=9) as refs, \
                    mock.patch.object(HELPER, "report_sources") as report:
                status = HELPER.main(["child-refs", "--root", "fixture repo", f"--{mode}"])
                self.assertEqual(status, 9)
                report.assert_not_called()
                refs.assert_called_once()
                args = refs.call_args.args[0]
                self.assertEqual(args.root, Path("fixture repo"))
                self.assertEqual(args.check, mode == "check")
                self.assertEqual(args.write, mode == "write")

    def test_child_refs_default_root_is_repository_not_support_directory(self):
        with mock.patch.object(HELPER, "sync_child_refs", return_value=0) as refs:
            self.assertEqual(HELPER.main(["child-refs", "--check"]), 0)
        self.assertEqual(refs.call_args.args[0].root, REPO_ROOT)

    def assert_cli_error(self, argv, message=None):
        stderr = io.StringIO()
        with mock.patch.object(HELPER, "report_sources") as report, \
                mock.patch.object(HELPER, "sync_child_refs") as refs, \
                contextlib.redirect_stderr(stderr), \
                self.assertRaises(SystemExit) as error:
            HELPER.main(argv)
        self.assertEqual(error.exception.code, 2)
        report.assert_not_called()
        refs.assert_not_called()
        if message:
            self.assertIn(message, stderr.getvalue())

    def test_explicit_subcommand_is_required(self):
        for argv in ([], ["sources.nix"], ["--write"], ["--root", "unused", "--write"]):
            with self.subTest(argv=argv):
                self.assert_cli_error(argv)

    def test_child_refs_requires_exactly_one_mode(self):
        for modes in ([], ["--check", "--write"]):
            with self.subTest(modes=modes):
                self.assert_cli_error(["child-refs", "--root", "unused", *modes])

    def test_report_sources_requires_sources(self):
        self.assert_cli_error(["report-sources", "--jobs", "2"])

    def test_invalid_jobs_are_rejected_before_dispatch(self):
        for jobs in ("0", "-1", "invalid"):
            with self.subTest(jobs=jobs):
                message = "positive integer" if jobs != "invalid" else "invalid int value"
                self.assert_cli_error(["report-sources", "--jobs", jobs, "sources.nix"], message)

    def test_command_specific_options_cannot_cross_dispatch_boundary(self):
        for argv in (
            ["report-sources", "--write", "sources.nix"],
            ["report-sources", "--root", "unused", "sources.nix"],
            ["report-sources", "--null", "sources.nix"],
            ["child-refs", "--check", "--jobs", "2"],
            ["child-refs", "--check", "--ansi"],
            ["child-refs", "--check", "--color=never"],
            ["child-refs", "--check", "--null"],
            ["flake-dirs", "--check"],
            ["flake-dirs", "--write"],
            ["flake-dirs", "--jobs", "2"],
            ["report-sources", "--color=invalid", "sources.nix"],
        ):
            with self.subTest(argv=argv):
                self.assert_cli_error(argv)

    def test_report_sources_never_discovers_refs_or_mutates_files(self):
        packages = [
            ("z-last", {"kind": "github-tags", "version": "1.0.0"}),
            ("a-first", {"kind": "github-tags", "version": "1.0.0"}),
        ]
        stdout = io.StringIO()
        with contextlib.ExitStack() as stack:
            for name in ("sync_child_refs", "root_urls", "discover_wrappers", "update_wrapper"):
                stack.enter_context(mock.patch.object(
                    HELPER, name, side_effect=AssertionError(f"report must not call {name}"),
                ))
            stack.enter_context(mock.patch.object(
                Path, "write_text", side_effect=AssertionError("report must not write"),
            ))
            stack.enter_context(mock.patch.object(
                Path, "write_bytes", side_effect=AssertionError("report must not write"),
            ))
            load = stack.enter_context(mock.patch.object(HELPER, "load_packages", return_value=packages))
            stack.enter_context(mock.patch.object(HELPER, "latest_value", return_value="1.1.0"))
            stack.enter_context(contextlib.redirect_stdout(stdout))
            status = HELPER.main(["report-sources", "--jobs", "2", "--color=never", "sources.nix"])
        self.assertEqual(status, 0)
        load.assert_called_once_with([Path("sources.nix")])
        self.assertEqual(stdout.getvalue().splitlines(), [
            "- a-first: 1.0.0 -> 1.1.0",
            "- z-last: 1.0.0 -> 1.1.0",
        ])

    def test_report_sources_load_failure_status_is_retained(self):
        stderr = io.StringIO()
        with mock.patch.object(HELPER, "load_packages", side_effect=RuntimeError("bad source")), \
                contextlib.redirect_stderr(stderr):
            self.assertEqual(HELPER.main(["report-sources", "sources.nix"]), 1)
        self.assertIn("bad source", stderr.getvalue())

    def test_report_sources_lookup_failure_status_is_retained(self):
        packages = [("example", {"kind": "github-tags", "version": "1.0.0"})]
        stdout = io.StringIO()
        with mock.patch.object(HELPER, "load_packages", return_value=packages), \
                mock.patch.object(HELPER, "latest_value", side_effect=RuntimeError("offline")), \
                contextlib.redirect_stdout(stdout):
            self.assertEqual(HELPER.main(["report-sources", "--color=never", "sources.nix"]), 1)
        self.assertIn("[check failed: offline]", stdout.getvalue())

    def test_child_refs_never_reports_evaluates_sources_or_uses_network(self):
        TMP_ROOT.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="test-helper-cli.", dir=TMP_ROOT) as directory:
            root = Path(directory)
            wrapper = root / "pkgs/example/flake.nix"
            wrapper.parent.mkdir(parents=True)
            wrapper.write_text("unchanged fixture\n")
            for mode in ("--check", "--write"):
                with self.subTest(mode=mode), contextlib.ExitStack() as stack:
                    for name in ("report_sources", "load_sources", "load_packages", "request_json",
                                 "latest_value", "report_package"):
                        stack.enter_context(mock.patch.object(
                            HELPER, name, side_effect=AssertionError(f"refs must not call {name}"),
                        ))
                    stack.enter_context(mock.patch.object(
                        HELPER.subprocess, "run", side_effect=AssertionError("refs must be offline"),
                    ))
                    stack.enter_context(mock.patch.object(
                        HELPER.urllib.request, "urlopen",
                        side_effect=AssertionError("refs must not use network"),
                    ))
                    refs = stack.enter_context(mock.patch.object(HELPER, "root_urls", return_value={}))
                    discovery = stack.enter_context(mock.patch.object(
                        HELPER, "discover_wrappers", return_value=[wrapper],
                    ))
                    stack.enter_context(mock.patch.object(
                        HELPER, "update_wrapper", return_value="unchanged fixture\n",
                    ))
                    stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
                    self.assertEqual(HELPER.main(["child-refs", "--root", str(root), mode]), 0)
                    refs.assert_called_once_with(root)
                    discovery.assert_called_once_with(root)
                self.assertEqual(wrapper.read_text(), "unchanged fixture\n")


if __name__ == "__main__":
    unittest.main()
