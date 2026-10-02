from contextlib import contextmanager
import copy
import ctypes
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


SCRIPT = Path(__file__).parents[1] / "spike.py"
SPEC = importlib.util.spec_from_file_location("rust_unit_spike", SCRIPT)
SPIKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SPIKE)


def synthetic_unit():
    """Explicitly synthetic exact values, never evidence of producer success."""
    values = {
        "context": {key: "a" * 64 for key in ("cargo", "rustc", "config")},
        "package": {"id": "registry+fixture#leaf@1.0.0", "source_digest": "b" * 64},
        "target": {"name": "leaf", "kinds": ["lib"]},
        "role": "target",
        "triple": "x86_64-unknown-linux-gnu",
        "features": ["serde", "default"],
        "profile": {"opt_level": "0", "debug_assertions": True},
        "rustflags": ["-C", "opt-level=0"],
        "edges": [{"dependency_descriptor": "c" * 64, "extern_name": "serde", "kind": "normal"}],
        "build_script": {"status": "not_applicable"},
    }
    return {name: {"status": "exact", "value": value} for name, value in values.items()}


def successful_probe(command, cwd, env, timeout):
    if "metadata" in command and "--help" not in command:
        text = json.dumps({"packages": [{"id": "fixture"}], "resolve": None})
    else:
        text = "--offline --locked --no-deps --format-version --filter-platform --message-format"
    return {"command": command, "status": "ok", "returncode": 0, "stdout": text, "stderr": ""}


@contextmanager
def decoder_limit_payloads():
    # Recent CPython C-decoder limits differ from the Python recursion limit.
    depth = max(20000, sys.getrecursionlimit() + 100)
    payloads = {
        "nesting": (RecursionError, '{"payload":' + "[" * depth + "0" + "]" * depth + "}"),
    }
    previous = None
    if hasattr(sys, "set_int_max_str_digits"):
        previous = sys.get_int_max_str_digits()
        sys.set_int_max_str_digits(640)
        payloads["integer"] = (ValueError, '{"payload":' + "1" * 641 + "}")
    try:
        yield payloads
    finally:
        if previous is not None:
            sys.set_int_max_str_digits(previous)


class DescriptorTests(unittest.TestCase):
    def test_every_exact_field_is_required(self):
        for name in SPIKE.EXACT_FIELDS:
            for status in (None, "unknown", "observed", "unsupported"):
                with self.subTest(field=name, status=status):
                    unit = synthetic_unit()
                    if status is None:
                        del unit[name]
                    else:
                        unit[name]["status"] = status
                    with self.assertRaisesRegex(ValueError, "not exact"):
                        SPIKE.descriptor(unit)

    def test_no_inference_from_artifact_or_package_fixtures(self):
        fixtures = [
            {"reason": "compiler-artifact", "package_id": "fixture",
             "target": {"kind": ["lib"]}, "features": ["default"]},
            {"packages": [{"id": "fixture", "features": {"default": []}}],
             "resolve": {"nodes": [{"id": "fixture", "features": ["default"]}]}},
            {"exact": True, "producer_qualified": True},
        ]
        for fixture in fixtures:
            with self.assertRaises(ValueError):
                SPIKE.descriptor(fixture)
        for source in ("metadata", "compiler_messages", "forged_exact"):
            self.assertTrue(all(not field["exact"] for field in SPIKE.fidelity(source).values()))

    def test_shared_exact_descriptors_ignore_only_order_and_consumer_labels(self):
        left = synthetic_unit()
        right = copy.deepcopy(left)
        right["demand"] = "other-member"
        right["features"]["value"] = ["default", "serde", "serde"]
        self.assertEqual(SPIKE.descriptor(left)["sha256"], SPIKE.descriptor(right)["sha256"])
        self.assertFalse(SPIKE.descriptor(right)["producer_qualified"])
        self.assertEqual(SPIKE.descriptor(right)["scope"], "synthetic_schema_only")

    def test_equivalent_units_converge_across_plan_capsule_and_lock_stamps(self):
        left = synthetic_unit()
        right = synthetic_unit()
        for name in ("plan_stamp", "capsule_stamp", "lock_stamp"):
            left[name] = "e" * 64
            right[name] = "f" * 64
        result = SPIKE.descriptor(left)
        other = SPIKE.descriptor(right)
        self.assertEqual(result["sha256"], other["sha256"])
        self.assertEqual(result["descriptor"], other["descriptor"])
        self.assertNotIn("lock", result["descriptor"]["context"])
        self.assertFalse(result["producer_qualified"])
        self.assertFalse(other["producer_qualified"])

    def test_descriptor_snapshots_all_nested_inputs_before_hashing(self):
        unit = synthetic_unit()
        unit["profile"]["value"]["nested"] = {"settings": ["original"]}
        unit["build_script"]["value"] = {
            "status": "build_time_input", "inputs_identity": "e" * 64,
            "result_producer_identity": "f" * 64,
        }
        result = SPIKE.descriptor(unit)
        snapshot = copy.deepcopy(result)
        unit["profile"]["value"]["nested"]["settings"].append("mutated")
        for field in unit.values():
            value = field["value"]
            if isinstance(value, dict):
                value.clear()
            elif isinstance(value, list):
                for item in value:
                    if isinstance(item, dict):
                        item.clear()
                value.clear()
        self.assertEqual(result, snapshot)
        self.assertEqual(result["sha256"],
                         SPIKE.digest(SPIKE.encode(result["descriptor"]).encode()))

    def test_lock_cannot_be_smuggled_into_canonical_context(self):
        unit = synthetic_unit()
        unit["context"]["value"]["lock"] = "a" * 64
        with self.assertRaisesRegex(ValueError, "incomplete context"):
            SPIKE.descriptor(unit)

    def test_build_script_result_is_a_synthetic_build_time_input_reference(self):
        unit = synthetic_unit()
        unit["build_script"]["value"] = {
            "status": "build_time_input", "inputs_identity": "e" * 64,
            "result_producer_identity": "f" * 64,
        }
        result = SPIKE.descriptor(unit)
        self.assertEqual(result["descriptor"]["build_script"]["status"], "build_time_input")
        self.assertFalse(result["producer_qualified"])
        unit["build_script"]["value"] = {
            "status": "executed", "inputs_digest": "e" * 64, "outputs_digest": "f" * 64,
        }
        with self.assertRaisesRegex(ValueError, "build-time input"):
            SPIKE.descriptor(unit)

    def test_exact_divergence_changes_identity(self):
        base = synthetic_unit()
        variants = {
            "context": {"cargo": "d" * 64, "rustc": "a" * 64, "config": "a" * 64},
            "package": {"id": "registry+fixture#leaf@1.0.0", "source_digest": "d" * 64},
            "target": {"name": "leaf", "kinds": ["proc-macro"]},
            "role": "host",
            "triple": "aarch64-unknown-linux-gnu",
            "features": ["default"],
            "profile": {"opt_level": "3", "debug_assertions": False},
            "rustflags": ["-C", "opt-level=3"],
            "edges": [{"dependency_descriptor": "d" * 64, "extern_name": "serde", "kind": "build"}],
            "build_script": {"status": "build_time_input", "inputs_identity": "e" * 64,
                             "result_producer_identity": "f" * 64},
        }
        for name, value in variants.items():
            with self.subTest(field=name):
                unit = copy.deepcopy(base)
                unit[name]["value"] = value
                self.assertNotEqual(SPIKE.descriptor(base)["sha256"], SPIKE.descriptor(unit)["sha256"])

    def test_unordered_edges_but_ordered_rustflags(self):
        left = synthetic_unit()
        left["edges"]["value"].append(
            {"dependency_descriptor": "d" * 64, "extern_name": "core", "kind": "normal"}
        )
        right = copy.deepcopy(left)
        right["edges"]["value"].reverse()
        self.assertEqual(SPIKE.descriptor(left)["sha256"], SPIKE.descriptor(right)["sha256"])
        right["rustflags"]["value"].reverse()
        self.assertNotEqual(SPIKE.descriptor(left)["sha256"], SPIKE.descriptor(right)["sha256"])

    def test_missing_values_and_incomplete_effects_fail_closed(self):
        variants = {
            "context": {"cargo": "a" * 64}, "package": {"id": "fixture"},
            "target": {"kinds": ["lib"]}, "role": "inferred-host", "triple": None,
            "features": None, "profile": {}, "rustflags": None,
            "edges": [{"extern_name": "serde", "kind": "normal"}],
            "build_script": {"status": "executed", "outputs_digest": "e" * 64},
        }
        for name, value in variants.items():
            with self.subTest(field=name):
                unit = synthetic_unit()
                unit[name]["value"] = value
                with self.assertRaises(ValueError):
                    SPIKE.descriptor(unit)
        unit = synthetic_unit()
        del unit["features"]["value"]
        with self.assertRaises(ValueError):
            SPIKE.descriptor(unit)


class SafetyTests(unittest.TestCase):
    def test_authorization_gate_precedes_any_execution(self):
        with mock.patch.object(SPIKE, "run") as run, mock.patch("sys.stderr", io.StringIO()):
            with self.assertRaises(SystemExit):
                SPIKE.main(["capture-build", "--repo", ".", "--output-dir", "tmp/test",
                            "--package", "fixture"])
            run.assert_not_called()

    def test_main_reports_keyboard_interrupt_without_traceback(self):
        stderr = io.StringIO()
        with mock.patch.object(SPIKE, "run", side_effect=KeyboardInterrupt()), \
                mock.patch("sys.stderr", stderr):
            status = SPIKE.main(["probe", "--repo", ".", "--output-dir", "tmp/test"])
        self.assertEqual(status, 130)
        self.assertEqual(stderr.getvalue(), "rust-unit-spike: interrupted\n")

    def test_cheap_phase_rejects_expensive_options_and_timeout(self):
        for extra in (["--allow-expensive-build"], ["--package", "fixture"], ["--timeout", "31"]):
            with mock.patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit):
                SPIKE.arguments(["probe", "--repo", ".", "--output-dir", "tmp/test", *extra])

    def test_rustup_proxy_is_rejected_without_invoking_it(self):
        with mock.patch.object(SPIKE.shutil, "which", return_value="/nonexistent/rustup"):
            with self.assertRaisesRegex(ValueError, "rustup"):
                SPIKE.local_tool("cargo")

    def test_external_output_is_rejected_without_writing(self):
        with self.assertRaisesRegex(ValueError, "output must"):
            SPIKE.output_folder(Path("/external-output-disallowed"))

    def test_capability_failure_is_unknown_not_unsupported(self):
        self.assertEqual(SPIKE.capability({"status": "failed", "stdout": "--locked"}, "--locked"),
                         "unknown")

    def test_messages_never_qualify_graph_even_with_features_and_script(self):
        text = "\n".join(json.dumps(value) for value in (
            {"reason": "compiler-artifact", "features": ["default"], "producer_qualified": True},
            {"reason": "build-script-executed", "cfgs": ["native"], "env": [["FOO", "bar"]]},
        ))
        result = SPIKE.messages(text)
        self.assertEqual(result["counts"], {"compiler-artifact": 1, "build-script-executed": 1})
        self.assertFalse(result["exact_graph"])
        self.assertTrue(all(not field["exact"] for field in result["fidelity"].values()))


    def test_malformed_message_reason_shapes_are_counted_not_raised(self):
        invalid = [{"reason": value} for value in ([], {}, None, 1, True)]
        invalid += [{}, [], None, "compiler-artifact"]
        text = "\n".join(json.dumps(value) for value in [
            *invalid, {"reason": "future-valid-message"}, {"reason": "compiler-artifact"},
        ]) + "\nnot-json"
        result = SPIKE.messages(text)
        self.assertEqual(result["malformed_lines"], len(invalid) + 1)
        self.assertEqual(result["counts"]["compiler-artifact"], 1)
        self.assertFalse(result["exact_graph"])


    def test_message_decoder_limits_count_malformed_lines_and_continue(self):
        with decoder_limit_payloads() as payloads:
            for name, (error, text) in payloads.items():
                with self.subTest(limit=name):
                    with self.assertRaises(error):
                        json.loads(text)
                    result = SPIKE.messages(text + '\n{"reason":"compiler-artifact"}\n')
                    self.assertEqual(result["malformed_lines"], 1)
                    self.assertEqual(result["counts"]["compiler-artifact"], 1)
                    self.assertFalse(result["exact_graph"])

    def test_message_processing_errors_are_not_decoder_failures(self):
        class BrokenMessage(dict):
            def get(self, key):
                raise error("synthetic processing error")

        for error in (ValueError, RecursionError):
            with self.subTest(error=error), \
                    mock.patch.object(SPIKE.json, "loads", return_value=BrokenMessage()):
                with self.assertRaisesRegex(error, "synthetic processing error"):
                    SPIKE.messages("{}")


class RunnerTests(unittest.TestCase):
    def setUp(self):
        SPIKE.TMP_ROOT.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="rust-unit-spike-test-", dir=SPIKE.TMP_ROOT)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        (self.repo / "Cargo.toml").write_text("[workspace]\nmembers = []\n")
        (self.repo / "Cargo.lock").write_text("# synthetic fixture, not resolved\nversion = 4\n")
        self.tool = self.root / "fixture-tool"
        self.tool.write_text("synthetic local binary fingerprint")

    def args(self, *extra):
        return SPIKE.arguments(["probe", "--repo", str(self.repo), "--output-dir",
                                str(self.root / "output"), *extra])

    def test_repeat_report_is_deterministic_and_never_producer_pass(self):
        with mock.patch.object(SPIKE, "local_tool", return_value=self.tool), \
                mock.patch.object(SPIKE, "probe", side_effect=successful_probe) as probe:
            args = self.args("--metadata-no-deps")
            left = SPIKE.run(args)
            args.output_dir = self.root / "other-output"
            right = SPIKE.run(args)
        self.assertEqual(SPIKE.encode(left), SPIKE.encode(right))
        self.assertFalse(left["producer"]["qualified"])
        self.assertEqual(left["producer"]["decision"], "not_proven")
        self.assertEqual(left["canonicalization"]["eligible_exact_descriptors"], 0)
        self.assertTrue(left["lock_unchanged"])
        self.assertEqual(left["plan_freshness"]["lock_sha256"], left["inputs"]["lock"]["sha256"])
        self.assertEqual(left["plan_freshness"]["scope"], "plan_freshness_only_not_unit_identity")
        self.assertFalse(left["metadata"]["resolve_present"])
        for call in probe.call_args_list:
            cmd, cwd, env, timeout = call.args
            self.assertNotIn("build", cmd if "--help" not in cmd else [])
            self.assertTrue(Path(env["TMPDIR"]).is_relative_to(SPIKE.TMP_ROOT))
            self.assertEqual(env["CARGO_NET_OFFLINE"], "true")
            if "--no-deps" in cmd:
                self.assertIn("--locked", cmd)
                self.assertIn("--offline", cmd)

    def test_output_children_cannot_escape_via_existing_symlinks(self):
        out = self.root / "output"
        out.mkdir()
        sentinel = self.root / "sentinel"
        sentinel.write_text("unchanged")
        (out / "report.json").symlink_to(sentinel)
        with self.assertRaisesRegex(ValueError, "output child must not be a symlink"):
            SPIKE.output_folder(out)
        self.assertEqual(sentinel.read_text(), "unchanged")

    def test_report_hardlink_to_any_inspected_input_is_rejected_before_execution(self):
        config = self.repo / ".cargo/config.toml"
        config.parent.mkdir()
        config.write_text("# fixture")
        out = self.root / "output"
        out.mkdir()
        report = out / "report.json"
        for path in (self.repo / "Cargo.lock", self.repo / "Cargo.toml", self.tool, config):
            with self.subTest(path=path):
                before = path.read_bytes()
                os.link(path, report)
                try:
                    with mock.patch.object(SPIKE, "local_tool", return_value=self.tool), \
                            mock.patch.object(SPIKE, "probe") as probe:
                        with self.assertRaisesRegex(ValueError, "aliases inspected input"):
                            SPIKE.run(self.args())
                        probe.assert_not_called()
                    self.assertEqual(path.read_bytes(), before)
                finally:
                    report.unlink()

    def test_report_alias_created_during_probe_is_rejected(self):
        lock = self.repo / "Cargo.lock"
        before = lock.read_bytes()

        def alias(command, cwd, env, timeout):
            report = self.root / "output/report.json"
            if not report.exists():
                os.link(lock, report)
            return successful_probe(command, cwd, env, timeout)

        with mock.patch.object(SPIKE, "local_tool", return_value=self.tool), \
                mock.patch.object(SPIKE, "probe", side_effect=alias):
            with self.assertRaisesRegex(ValueError, "aliases inspected input"):
                SPIKE.run(self.args())
        self.assertEqual(lock.read_bytes(), before)
        self.assertEqual(list((self.root / "output").glob(".report-*")), [])

    def test_report_publication_replaces_inode_without_truncating_it(self):
        out = SPIKE.output_folder(self.root / "output")
        old = out / "report.json"
        old.write_text("previous complete report")
        witness = self.root / "old-report"
        os.link(old, witness)
        SPIKE.publish_report(out, {"complete": True}, [self.tool])
        self.assertEqual(json.loads(old.read_text()), {"complete": True})
        self.assertEqual(witness.read_text(), "previous complete report")
        self.assertFalse(old.samefile(witness))
        self.assertEqual(list(out.glob(".report-*")), [])

    def test_failed_atomic_publication_preserves_old_report_and_cleans_temp(self):
        out = SPIKE.output_folder(self.root / "output")
        old = out / "report.json"
        old.write_text("previous complete report")
        with mock.patch.object(SPIKE.os, "replace", side_effect=OSError("synthetic failure")):
            with self.assertRaisesRegex(OSError, "synthetic failure"):
                SPIKE.publish_report(out, {"complete": True}, [self.tool])
        self.assertEqual(old.read_text(), "previous complete report")
        self.assertEqual(list(out.glob(".report-*")), [])

    def test_interrupt_during_publication_preserves_old_report_and_cleans_temp(self):
        out = SPIKE.output_folder(self.root / "output")
        old = out / "report.json"
        old.write_text("previous complete report")
        with mock.patch.object(SPIKE.os, "replace", side_effect=KeyboardInterrupt()):
            with self.assertRaises(KeyboardInterrupt):
                SPIKE.publish_report(out, {"complete": True}, [self.tool])
        self.assertEqual(old.read_text(), "previous complete report")
        self.assertEqual(list(out.glob(".report-*")), [])

    def test_reused_output_and_nested_symlink_state_are_never_consumed(self):
        out = self.root / "output"
        out.mkdir()
        sentinel = self.root / "sentinel"
        sentinel.write_text("unchanged")
        for child in ("cargo-home", "target", "runtime", ".cargo"):
            nested = out / child / "nested"
            nested.mkdir(parents=True)
            (nested / "config.toml").symlink_to(sentinel)
        with mock.patch.object(SPIKE, "local_tool", return_value=self.tool), \
                mock.patch.object(SPIKE, "probe") as probe:
            with self.assertRaisesRegex(ValueError, "already exists.*fresh per-run"):
                SPIKE.run(self.args())
            probe.assert_not_called()
        self.assertEqual(sentinel.read_text(), "unchanged")

    def test_second_run_requires_new_exclusive_writable_state(self):
        observed = []

        def inspect(command, cwd, env, timeout):
            state = tuple(Path(env[key]) for key in ("CARGO_HOME", "CARGO_TARGET_DIR", "TMPDIR"))
            if not observed or state != observed[-1]:
                self.assertTrue(all(path.is_dir() and not list(path.iterdir()) for path in state))
                for path in state:
                    (path / "marker").write_text("prior run state")
                observed.append(state)
            return successful_probe(command, cwd, env, timeout)

        with mock.patch.object(SPIKE, "local_tool", return_value=self.tool), \
                mock.patch.object(SPIKE, "probe", side_effect=inspect) as probe:
            args = self.args()
            SPIKE.run(args)
            count = probe.call_count
            with self.assertRaisesRegex(ValueError, "already exists"):
                SPIKE.run(args)
            self.assertEqual(probe.call_count, count)
            args.output_dir = self.root / "second-output"
            SPIKE.run(args)
        self.assertEqual(len(observed), 2)
        self.assertTrue(set(observed[0]).isdisjoint(observed[1]))

    def test_malformed_build_messages_still_publish_incomplete_report(self):
        args = SPIKE.arguments([
            "capture-build", "--repo", str(self.repo), "--output-dir", str(self.root / "output"),
            "--package", "fixture", "--allow-expensive-build",
        ])

        def malformed(command, cwd, env, timeout):
            result = successful_probe(command, cwd, env, timeout)
            if "--message-format=json" in command:
                result["stdout"] = '{"reason": []}\n{"reason": {}}\n'
            return result

        with mock.patch.object(SPIKE, "local_tool", return_value=self.tool), \
                mock.patch.object(SPIKE, "probe", side_effect=malformed):
            report = SPIKE.run(args)
        self.assertEqual(report["compiler_messages"]["malformed_lines"], 2)
        self.assertFalse(report["producer"]["qualified"])
        self.assertEqual(json.loads((args.output_dir / "report.json").read_text()), report)

    def test_build_decoder_limits_still_publish_incomplete_reports(self):
        with decoder_limit_payloads() as payloads:
            for name, (_, text) in payloads.items():
                with self.subTest(limit=name):
                    args = SPIKE.arguments([
                        "capture-build", "--repo", str(self.repo),
                        "--output-dir", str(self.root / name), "--package", "fixture",
                        "--allow-expensive-build",
                    ])

                    def malformed(command, cwd, env, timeout):
                        result = successful_probe(command, cwd, env, timeout)
                        if "--message-format=json" in command:
                            result["stdout"] = text + '\n{"reason":"compiler-artifact"}\n'
                        return result

                    with mock.patch.object(SPIKE, "local_tool", return_value=self.tool), \
                            mock.patch.object(SPIKE, "probe", side_effect=malformed):
                        report = SPIKE.run(args)
                    self.assertEqual(report["compiler_messages"]["malformed_lines"], 1)
                    self.assertEqual(report["compiler_messages"]["counts"]["compiler-artifact"], 1)
                    self.assertFalse(report["producer"]["qualified"])
                    self.assertTrue(report["lock_unchanged"])
                    self.assertTrue(report["manifest_unchanged"])
                    self.assertEqual(json.loads((args.output_dir / "report.json").read_text()), report)

    def test_metadata_decoder_limits_still_publish_invalid_json_reports(self):
        with decoder_limit_payloads() as payloads:
            for name, (_, text) in payloads.items():
                with self.subTest(limit=name):
                    args = self.args("--metadata-no-deps")
                    args.output_dir = self.root / name

                    def malformed(command, cwd, env, timeout):
                        result = successful_probe(command, cwd, env, timeout)
                        if "--no-deps" in command:
                            result["stdout"] = text
                        return result

                    with mock.patch.object(SPIKE, "local_tool", return_value=self.tool), \
                            mock.patch.object(SPIKE, "probe", side_effect=malformed):
                        report = SPIKE.run(args)
                    self.assertEqual(report["metadata"]["status"], "invalid_json")
                    self.assertNotIn("package_count", report["metadata"])
                    self.assertFalse(report["producer"]["qualified"])
                    self.assertTrue(report["lock_unchanged"])
                    self.assertTrue(report["manifest_unchanged"])
                    self.assertEqual(json.loads((args.output_dir / "report.json").read_text()), report)

    def test_metadata_processing_errors_are_not_decoder_failures(self):
        class BrokenMetadata(dict):
            def get(self, key):
                raise error("synthetic processing error")

        for error in (ValueError, RecursionError):
            args = self.args("--metadata-no-deps")
            args.output_dir = self.root / error.__name__
            with self.subTest(error=error), \
                    mock.patch.object(SPIKE, "local_tool", return_value=self.tool), \
                    mock.patch.object(SPIKE, "probe", side_effect=successful_probe), \
                    mock.patch.object(SPIKE.json, "loads", return_value=BrokenMetadata(packages=[])):
                with self.assertRaisesRegex(error, "synthetic processing error"):
                    SPIKE.run(args)
            self.assertFalse((args.output_dir / "report.json").exists())

    def test_help_only_never_runs_metadata_or_a_build(self):
        with mock.patch.object(SPIKE, "local_tool", return_value=self.tool), \
                mock.patch.object(SPIKE, "probe", side_effect=successful_probe) as probe:
            report = SPIKE.run(self.args())
        tails = [call.args[0][1:] for call in probe.call_args_list]
        self.assertEqual(tails, [
            ["--version", "--verbose"], ["-vV"], ["metadata", "--help"],
            ["build", "--help"], ["-Z", "help"],
        ])
        self.assertEqual(report["metadata"]["status"], "not_run")
        self.assertTrue(report["manifest_unchanged"])

    def test_failed_metadata_and_help_remain_unknown_and_unqualified(self):
        def failure(command, cwd, env, timeout):
            return {"command": command, "status": "timeout", "returncode": None,
                    "stdout": "", "stderr": ""}

        with mock.patch.object(SPIKE, "local_tool", return_value=self.tool), \
                mock.patch.object(SPIKE, "probe", side_effect=failure):
            report = SPIKE.run(self.args("--metadata-no-deps"))
        self.assertEqual(report["metadata"]["status"], "timeout")
        self.assertEqual(report["capabilities"]["no-deps"]["status"], "unknown")
        self.assertFalse(report["producer"]["qualified"])
        self.assertEqual(report["canonicalization"]["eligible_exact_descriptors"], 0)

    def test_lock_change_invalidates_evidence_without_restoring_real_files(self):
        def changed(command, cwd, env, timeout):
            (self.repo / "Cargo.lock").write_text("changed synthetic fixture")
            return successful_probe(command, cwd, env, timeout)

        with mock.patch.object(SPIKE, "local_tool", return_value=self.tool), \
                mock.patch.object(SPIKE, "probe", side_effect=changed):
            report = SPIKE.run(self.args())
        self.assertFalse(report["lock_unchanged"])
        self.assertFalse(report["producer"]["qualified"])
        self.assertIn("evidence invalid", report["producer"]["reason"])

    def test_alternative_lock_cannot_silently_be_ignored(self):
        other = self.repo / "Other.lock"
        other.write_text("fixture")
        with mock.patch.object(SPIKE, "probe") as probe:
            with self.assertRaisesRegex(ValueError, "own Cargo.lock"):
                SPIKE.run(self.args("--metadata-no-deps", "--lockfile", str(other)))
            probe.assert_not_called()

    def test_authorized_build_rejects_the_real_checkout_before_execution(self):
        args = SPIKE.arguments([
            "capture-build", "--repo", str(SPIKE.CHECKOUT),
            "--output-dir", str(self.root / "output"),
            "--package", "fixture", "--allow-expensive-build",
        ])
        with mock.patch.object(SPIKE, "probe") as probe:
            with self.assertRaisesRegex(ValueError, "isolated repository"):
                SPIKE.run(args)
            probe.assert_not_called()

    def test_authorized_build_is_bounded_offline_locked_and_still_incomplete(self):
        args = SPIKE.arguments([
            "capture-build", "--repo", str(self.repo), "--output-dir", str(self.root / "output"),
            "--package", "fixture", "--timeout", "60", "--allow-expensive-build",
        ])
        with mock.patch.object(SPIKE, "local_tool", return_value=self.tool), \
                mock.patch.object(SPIKE, "probe", side_effect=successful_probe) as probe:
            report = SPIKE.run(args)
        cmd = probe.call_args_list[-1].args[0]
        self.assertIn("build", cmd)
        for token in ("--offline", "--locked", "--message-format=json", "--jobs"):
            self.assertIn(token, cmd)
        self.assertFalse(report["producer"]["qualified"])
        self.assertFalse(report["compiler_messages"]["exact_graph"])

    def test_probe_wall_time_and_output_are_bounded(self):
        env = {**dict(SPIKE.os.environ), "TMPDIR": str(self.root)}
        timed = SPIKE.probe([sys.executable, "-c", "import time; time.sleep(10)"],
                            self.root, env, 0.1)
        self.assertEqual(timed["status"], "timeout")
        flooded = SPIKE.probe([sys.executable, "-c", "print('x' * 100000)"],
                              self.root, env, 5, max_bytes=1000)
        self.assertEqual(flooded["status"], "output_limit")
        self.assertLessEqual(len(flooded["stdout"]) + len(flooded["stderr"]), 1000)


@unittest.skipUnless(sys.platform == "linux", "descendant reaping tests require Linux prctl")
class ProcessCleanupTests(unittest.TestCase):
    def setUp(self):
        RunnerTests.setUp(self)
        # Adopt dummy orphans ourselves, so even their zombies are reaped.
        libc = ctypes.CDLL(None, use_errno=True)
        previous = ctypes.c_int()
        if libc.prctl(37, ctypes.byref(previous), 0, 0, 0) != 0:
            self.skipTest("cannot read child-subreaper state")
        if libc.prctl(36, 1, 0, 0, 0) != 0:
            self.skipTest("cannot enable child subreaper")
        self.addCleanup(lambda: libc.prctl(36, previous.value, 0, 0, 0))

    def descendant_probe(self, mode="success", exception=None):
        pidfile = self.root / "descendant.pid"
        code = """
import os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pid = os.fork()
if pid == 0:
    fd = os.open(os.devnull, os.O_WRONLY)
    os.dup2(fd, 1)
    os.dup2(fd, 2)
    os.close(fd)
    time.sleep(5)  # Self-bounded even if the harness cleanup regresses.
    os._exit(0)
with open(sys.argv[1], 'w') as stream:
    stream.write(str(pid))
if sys.argv[2] == 'flood':
    print('x' * 100000, flush=True)
if sys.argv[2] in ('sleep', 'flood'):
    time.sleep(5)
sys.exit(1 if sys.argv[2] == 'failed' else 0)
"""
        children = []
        popen = subprocess.Popen

        def spawn(*args, **kwargs):
            child = popen(*args, **kwargs)
            children.append(child)
            return child

        def reap_descendant(pid, kill=False):
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                waited, status = os.waitpid(pid, os.WNOHANG)
                if waited:
                    return status
                if kill:
                    os.kill(pid, signal.SIGKILL)
                    kill = False
                time.sleep(0.01)
            self.fail("dummy descendant was not killed/reaped within two seconds")

        def fallback_cleanup():
            for child in children:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=2)
            if pidfile.exists():
                try:
                    reap_descendant(int(pidfile.read_text()), kill=True)
                except ChildProcessError:
                    pass  # Already reaped by the assertion below.

        self.addCleanup(fallback_cleanup)
        selector = SPIKE.selectors.DefaultSelector()
        select = selector.select

        def interrupt_when_ready(timeout):
            deadline = time.monotonic() + 2
            while not pidfile.exists() or not pidfile.read_text():
                if time.monotonic() >= deadline:
                    self.fail("dummy child did not become ready")
                time.sleep(0.01)
            if isinstance(exception, KeyboardInterrupt):
                signal.raise_signal(signal.SIGINT)
            raise exception

        if exception is not None:
            selector.select = interrupt_when_ready
        else:
            selector.select = select
        started = time.monotonic()
        with mock.patch.object(SPIKE.subprocess, "Popen", side_effect=spawn), \
                mock.patch.object(SPIKE.selectors, "DefaultSelector", return_value=selector):
            command = [sys.executable, "-B", "-c", code, str(pidfile), mode]
            if exception is not None:
                with self.assertRaises(type(exception)):
                    SPIKE.probe(command, self.root, os.environ.copy(), 3)
                result = None
            else:
                timeout = 0.5 if mode == "sleep" else 3
                result = SPIKE.probe(command, self.root, os.environ.copy(), timeout, max_bytes=1000)
        self.assertLess(time.monotonic() - started, 4)
        self.assertIsNotNone(children[0].returncode)
        self.assertTrue(children[0].stdout.closed)
        self.assertTrue(children[0].stderr.closed)
        status = reap_descendant(int(pidfile.read_text()))
        self.assertTrue(os.WIFSIGNALED(status))
        self.assertEqual(os.WTERMSIG(status), signal.SIGKILL)
        with self.assertRaises(ProcessLookupError):
            os.killpg(children[0].pid, 0)
        return result

    def test_successful_orphan_is_killed_and_reaped(self):
        self.assertEqual(self.descendant_probe()["status"], "ok")

    def test_failed_parent_orphan_is_killed_and_reaped(self):
        self.assertEqual(self.descendant_probe("failed")["status"], "failed")

    def test_keyboard_interrupt_cleans_all_processes_before_propagating(self):
        self.descendant_probe("sleep", KeyboardInterrupt())

    def test_system_exit_cleans_all_processes_before_propagating(self):
        self.descendant_probe("sleep", SystemExit(7))

    def test_unexpected_exception_cleans_all_processes_before_propagating(self):
        self.descendant_probe("sleep", RuntimeError("synthetic selector failure"))

    def test_timeout_cleans_descendants(self):
        self.assertEqual(self.descendant_probe("sleep")["status"], "timeout")

    def test_output_limit_cleans_descendants(self):
        self.assertEqual(self.descendant_probe("flood")["status"], "output_limit")

    def test_cleanup_wait_is_bounded_and_closes_pipes_on_failure(self):
        child = mock.Mock(pid=123456789, stdout=io.BytesIO(), stderr=io.BytesIO())
        child.wait.side_effect = subprocess.TimeoutExpired("dummy", 1)
        with mock.patch.object(SPIKE.os, "killpg") as kill:
            with self.assertRaisesRegex(ValueError, "cleanup bound"):
                SPIKE.cleanup_child(child)
        kill.assert_called_once_with(child.pid, signal.SIGKILL)
        self.assertLessEqual(child.wait.call_args.kwargs["timeout"], 1)
        self.assertTrue(child.stdout.closed)
        self.assertTrue(child.stderr.closed)

    def test_cleanup_retries_interrupts_and_preserves_interrupt_exit(self):
        child = mock.Mock(pid=123456789, stdout=io.BytesIO(), stderr=io.BytesIO())
        child.wait.side_effect = [KeyboardInterrupt(), 0]
        with mock.patch.object(SPIKE.os, "killpg", side_effect=[InterruptedError(), None]) as kill:
            with self.assertRaises(KeyboardInterrupt):
                SPIKE.cleanup_child(child)
        self.assertEqual(kill.call_count, 2)
        self.assertEqual(child.wait.call_count, 2)
        self.assertTrue(child.stdout.closed)
        self.assertTrue(child.stderr.closed)


if __name__ == "__main__":
    unittest.main()
