"""Host-neutral CLI mocks; no subprocess or store executable is ever run."""

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import fixture
import product_semantic as runner


FINAL = {"derivationPath": "/nix/store/fake-product.drv", "output": "out",
         "storePath": "/nix/store/fake-product"}
BINARY = FINAL["storePath"] + "/bin/fake-agent"
EXPECTED = {"schemaVersion": 1, "versionStdout": "fake-agent 0.1.0\n",
            "resourceId": "fixture-resource", "missingResourceId": "missing-fixture",
            "operation": "resource_describe",
            "resourceManifest": {"schema_version": 1, "resources": [
                {"id": "fixture-resource", "data_paths": [runner.DATA_TOKEN]},
            ]}}


def source_hashes():
    return {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (Path(runner.__file__), Path(fixture.__file__))}


class FakeProcess:
    def __init__(self, code, stdout, stderr, hanging=False):
        self.pid = 99999999  # Never passed to a real signal operation.
        self.code = code
        self.hanging = hanging
        self.writers = []
        self.stdout = self.pipe(stdout)
        self.stderr = self.pipe(stderr)

    def pipe(self, content):
        reader, writer = os.pipe()
        # Every fake payload fits a pipe; overflow tested with a smaller bound.
        os.write(writer, content)
        if self.hanging:
            self.writers.append(writer)
        else:
            os.close(writer)
        return os.fdopen(reader, "rb")

    def poll(self):
        return None if self.hanging else self.code

    def wait(self, timeout):
        for writer in self.writers:
            os.close(writer)
        self.writers.clear()
        self.hanging = False
        return self.code


class SemanticTests(unittest.TestCase):
    def setUp(self):
        before = source_hashes()
        self.addCleanup(lambda: self.assertEqual(source_hashes(), before))
        self.temp = tempfile.TemporaryDirectory(
            dir=fixture.TMP_ROOT, prefix="product-semantic-test-"
        )
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / "fakeRepo"
        self.tmp = self.repo / "tmp"
        self.tmp.mkdir(parents=True)
        self.relative_write("source/manifest.json", b'{"fake":true}\n')
        self.source_sha = hashlib.sha256((self.repo / "source/manifest.json").read_bytes())
        self.addCleanup(self.assert_pristine)
        self.mode = "good"
        self.calls = []
        self.output = self.tmp / "accepted"
        self.popen = self.enterContext(patch.object(runner.subprocess, "Popen", self.cli))
        self.kill = self.enterContext(patch.object(runner.os, "killpg"))

    def relative_write(self, name, content):
        relative = Path(name)
        self.assertFalse(relative.is_absolute())
        self.assertNotIn("..", relative.parts)
        path = self.repo / relative
        self.assertTrue(path.is_relative_to(self.repo))
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    def assert_pristine(self):
        after = hashlib.sha256((self.repo / "source/manifest.json").read_bytes())
        self.assertEqual(self.source_sha.digest(), after.digest())

    def cli(self, command, *, cwd, env, stdin, stdout, stderr, start_new_session, pass_fds):
        self.assertEqual(command[0], BINARY)
        self.assertEqual(len(pass_fds), 1)
        self.assertEqual(cwd, Path(f"/proc/self/fd/{pass_fds[0]}"))
        self.assertTrue(Path(os.readlink(cwd)).is_relative_to(self.tmp))
        self.assertEqual(env["PATH"], "/does/not/exist")
        self.assertNotIn("ABIRD_HOST_AGENT_STATE_DIR", env)
        self.assertEqual(stdin, subprocess.DEVNULL)
        self.assertEqual((stdout, stderr), (subprocess.PIPE, subprocess.PIPE))
        self.assertTrue(start_new_session)
        self.calls.append(command)
        if command[1:] == ["--version"]:
            text = (b"fake-agent 9.9.9\n" if self.mode == "version"
                    else EXPECTED["versionStdout"].encode())
            return FakeProcess(0, text, b"")
        for flag in ("--systemctl", "--journalctl", "--runuser"):
            self.assertEqual(command[command.index(flag) + 1], "/does/not/exist")
        self.assertIn("--json", command)
        self.assertEqual(command[-4:-1], ["resource", "describe", "--resource"])
        manifest_path = Path(command[command.index("--resource-manifest") + 1])
        state = Path(command[command.index("--state-dir") + 1])
        self.assertEqual(manifest_path.parent, cwd)
        self.assertEqual(state, cwd / "state")
        manifest = json.loads(manifest_path.read_text())
        resource = manifest["resources"][0]
        data = Path(resource["data_paths"][0])
        self.assertEqual(data, cwd / "data-not-created")
        if command[-1] == EXPECTED["missingResourceId"]:
            error = {"ok": self.mode == "missing-status", "error":
                     "wrong error" if self.mode == "missing-error"
                     else "unknown resource missing-fixture"}
            return FakeProcess(0 if self.mode == "missing-exit" else 1,
                               b"{}" if self.mode == "missing-stdout" else b"",
                               b"not JSON" if self.mode == "missing-json"
                               else json.dumps(error).encode())
        self.assertEqual(command[-1], EXPECTED["resourceId"])
        if self.mode in ("state", "state-link"):
            if self.mode == "state-link":
                state.symlink_to("absent-target")
            else:
                state.mkdir()
        if self.mode in ("data", "data-link"):
            if self.mode == "data-link":
                data.symlink_to("absent-target")
            else:
                data.write_bytes(b"forbidden access")
        value = {"ok": True, "operation": EXPECTED["operation"],
                 "result": {"resource": resource}}
        if self.mode == "status":
            value["ok"] = False
        if self.mode == "integer-status":
            value["ok"] = 1
        if self.mode == "operation":
            value["operation"] = "service_stop"
        if self.mode == "resource":
            resource["id"] = "foreign-resource"
        if self.mode == "data-path":
            resource["data_paths"] = []
        text = json.dumps(value).encode()
        if self.mode == "json":
            text = b"not JSON"
        if self.mode == "duplicate-json":
            text = b'{"ok":true,"ok":false}'
        if self.mode == "non-object":
            text = b"[]"
        return FakeProcess(2 if self.mode == "exit" else 0, text, b"mock stderr\n",
                           hanging=self.mode == "timeout")

    def run_acceptance(self, expected=None, final=None, output=None):
        return runner.run_acceptance(
            BINARY, final or FINAL, expected or EXPECTED, output or self.output,
            output_root=self.tmp,
        )

    def reject(self, mode, message):
        self.mode = mode
        with self.assertRaisesRegex(runner.Failure, message):
            self.run_acceptance()
        self.assertFalse(os.path.lexists(self.output))
        self.assertEqual(list(self.tmp.iterdir()), [])

    def test_success_raw_evidence_and_named_flag(self):
        summary = self.run_acceptance()
        self.assertEqual(summary["final"], FINAL)
        self.assertFalse(summary["producer"]["qualified"])
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(json.loads((self.output / "summary.json").read_text()), summary)
        for case in ("version", "describe", "missing"):
            self.assertTrue((self.output / f"{case}.stdout").is_file())
            self.assertTrue((self.output / f"{case}.stderr").is_file())
            observation = json.loads((self.output / f"{case}.json").read_text())
            self.assertFalse(observation["stateExists"])
            self.assertFalse(observation["declaredDataExists"])
        self.assertEqual((self.output / "version.stdout").read_bytes(),
                         EXPECTED["versionStdout"].encode())

    def outside_fixture(self):
        outside = self.repo / "outside"
        outside.mkdir(exist_ok=True)
        sentinel = outside / "sentinel"
        sentinel.write_bytes(b"outside must not be truncated or cleaned\n")
        sentinel.chmod(0o640)
        before = (sentinel.read_bytes(), sentinel.stat().st_mode, outside.stat().st_mode)
        return outside, sentinel, before

    def assert_outside_unchanged(self, outside, sentinel, before):
        self.assertEqual((sentinel.read_bytes(), sentinel.stat().st_mode,
                          outside.stat().st_mode), before)
        self.assertEqual(list(outside.iterdir()), [sentinel])

    def reject_alias(self, hardlink):
        outside, sentinel, before = self.outside_fixture()
        names = ("version.stdout", "version.stderr", "version.json", "describe.stdout",
                 "describe.stderr", "describe.json", "missing.stdout", "missing.stderr",
                 "missing.json", "summary.json")
        for name in names:
            with self.subTest(name=name):
                def alias(command, **kwargs):
                    result = self.cli(command, **kwargs)
                    if command[1:] == ["--version"]:
                        stage_fd = kwargs["pass_fds"][0]
                        if hardlink:
                            os.link(sentinel, name, dst_dir_fd=stage_fd)
                        else:
                            os.symlink(sentinel, name, dir_fd=stage_fd)
                    return result

                with patch.object(runner.subprocess, "Popen", alias):
                    with self.assertRaises(FileExistsError):
                        self.run_acceptance()
                self.assert_outside_unchanged(outside, sentinel, before)
                self.assertEqual(sentinel.stat().st_nlink, 1)
                self.assertEqual(list(self.tmp.iterdir()), [])

    def test_cli_evidence_symlink_never_truncates_outside(self):
        self.reject_alias(hardlink=False)

    def test_cli_evidence_hardlink_never_truncates_outside(self):
        self.reject_alias(hardlink=True)

    def test_cli_parent_swap_fails_and_cleans_only_opened_stage(self):
        outside, sentinel, before = self.outside_fixture()
        moved = self.repo / "retained-tmp"

        def swap(command, **kwargs):
            result = self.cli(command, **kwargs)
            if command[1:] == ["--version"]:
                self.tmp.rename(moved)
                self.tmp.symlink_to(outside, target_is_directory=True)
            return result

        with patch.object(runner.subprocess, "Popen", swap):
            with self.assertRaisesRegex(runner.Failure, "directory binding changed"):
                self.run_acceptance()
        self.assert_outside_unchanged(outside, sentinel, before)
        self.assertTrue(self.tmp.is_symlink())
        self.assertEqual(list(moved.iterdir()), [])

    def test_cli_ancestor_swap_fails_without_outside_cleanup(self):
        outside, sentinel, before = self.outside_fixture()
        moved = Path(self.temp.name) / "retained-repo"
        original_repo = self.repo

        def swap(command, **kwargs):
            result = self.cli(command, **kwargs)
            if command[1:] == ["--version"]:
                original_repo.rename(moved)
                original_repo.symlink_to(moved / "outside", target_is_directory=True)
            return result

        try:
            with patch.object(runner.subprocess, "Popen", swap):
                with self.assertRaisesRegex(runner.Failure, "directory binding changed"):
                    self.run_acceptance()
            self.assert_outside_unchanged(moved / "outside", moved / "outside/sentinel", before)
            self.assertEqual(list((moved / "tmp").iterdir()), [])
        finally:
            # Restore only our mock-owned alias for the pristine-source cleanup.
            if original_repo.is_symlink():
                original_repo.unlink()
                moved.rename(original_repo)

    def test_cli_stage_swap_cleans_original_not_replacement(self):
        outside, sentinel, before = self.outside_fixture()

        def swap(command, **kwargs):
            result = self.cli(command, **kwargs)
            if command[1:] == ["--version"]:
                stage = Path(os.readlink(kwargs["cwd"]))
                stage.rename(self.tmp / "moved-stage")
                stage.symlink_to(outside, target_is_directory=True)
            return result

        with patch.object(runner.subprocess, "Popen", swap):
            with self.assertRaisesRegex(runner.Failure, "directory binding changed"):
                self.run_acceptance()
        self.assert_outside_unchanged(outside, sentinel, before)
        entries = list(self.tmp.iterdir())
        self.assertEqual(len(entries), 1)
        self.assertTrue(entries[0].is_symlink())
        self.assertFalse(os.path.lexists(self.tmp / "moved-stage"))

    def test_parent_swap_at_publication_removes_only_owned_output(self):
        outside, sentinel, before = self.outside_fixture()
        moved = self.repo / "retained-tmp"
        publish = fixture._publish_noreplace

        def swap(parent, stage, name):
            self.tmp.rename(moved)
            self.tmp.symlink_to(outside, target_is_directory=True)
            publish(parent, stage, name)

        with patch.object(fixture, "_publish_noreplace", swap):
            with self.assertRaisesRegex(runner.Failure, "directory binding changed"):
                self.run_acceptance()
        self.assert_outside_unchanged(outside, sentinel, before)
        self.assertEqual(list(moved.iterdir()), [])

    def test_specification_reads_regular_bounded_no_follow(self):
        outside, sentinel, before = self.outside_fixture()
        path = self.tmp / "expected.json"
        path.write_bytes(json.dumps(EXPECTED).encode())
        self.assertEqual(runner._read_regular_json(path), EXPECTED)
        with patch.object(runner, "MAX_SPEC_BYTES", 8):
            with self.assertRaisesRegex(runner.Failure, "byte limit"):
                runner._read_regular_json(path)
        path.unlink()
        path.symlink_to(sentinel)
        with self.assertRaises(OSError):
            runner._read_regular_json(path)
        path.unlink()
        path.mkdir()
        with self.assertRaisesRegex(runner.Failure, "regular file"):
            runner._read_regular_json(path)
        self.assert_outside_unchanged(outside, sentinel, before)
        self.assertEqual(self.calls, [])

    def test_wrong_version(self):
        self.reject("version", "version")

    def test_malformed_json(self):
        for mode in ("json", "duplicate-json", "non-object"):
            with self.subTest(mode=mode):
                self.reject(mode, "JSON|status")

    def test_wrong_resource(self):
        self.reject("resource", "wrong resource")

    def test_wrong_operation(self):
        self.reject("operation", "wrong operation")

    def test_false_or_nonboolean_status(self):
        for mode in ("status", "integer-status"):
            with self.subTest(mode=mode):
                self.reject(mode, "status")

    def test_unexpected_exit(self):
        self.reject("exit", "unexpected exit 2")

    def test_missing_exit(self):
        self.reject("missing-exit", "unexpected exit 0")

    def test_missing_error_or_stdout(self):
        for mode in ("missing-error", "missing-stdout", "missing-status"):
            with self.subTest(mode=mode):
                self.reject(mode, "named resource error")

    def test_missing_malformed_json(self):
        self.reject("missing-json", "malformed JSON")

    def test_timeout(self):
        with patch.object(runner, "TIMEOUT_SECONDS", 0.01):
            self.reject("timeout", "timeout")
        self.kill.assert_called_once()

    def test_log_bounded_during_execution(self):
        with patch.object(runner, "MAX_LOG_BYTES", 32):
            self.reject("good", "log byte limit")
        self.kill.assert_called_once()

    def test_state_creation_including_dangling_link(self):
        for mode in ("state", "state-link"):
            with self.subTest(mode=mode):
                self.reject(mode, "state or declared data")

    def test_declared_data_access_including_dangling_link(self):
        for mode in ("data", "data-link"):
            with self.subTest(mode=mode):
                self.reject(mode, "state or declared data")

    def test_wrong_declared_data(self):
        self.reject("data-path", "data path was not preserved")

    def test_existing_and_dangling_output(self):
        self.output.symlink_to("missing")
        with self.assertRaises(FileExistsError):
            self.run_acceptance()
        self.assertTrue(self.output.is_symlink())
        self.assertEqual(self.calls, [])

    def test_symlink_parent(self):
        link = self.tmp / "link"
        link.symlink_to(self.tmp, target_is_directory=True)
        with self.assertRaises(OSError):
            self.run_acceptance(output=link / "output")
        self.assertEqual(self.calls, [])

    def test_relative_output_fence(self):
        with patch.object(runner.os.path, "abspath", wraps=os.path.abspath):
            with self.assertRaisesRegex(runner.Failure, "output root"):
                self.run_acceptance(output="tmp/not-the-fakeRepo")
        self.assertEqual(self.calls, [])

    def test_traversal_and_secret_fence(self):
        for name in ("../escape", "secrets/output", "private.key/output"):
            with self.subTest(name=name), self.assertRaises(runner.Failure):
                self.run_acceptance(output=self.tmp / name)
        self.assertEqual(self.calls, [])

    def test_atomic_no_replace_race(self):
        original = fixture._publish_noreplace

        def collide(parent, stage, name):
            self.output.mkdir()
            (self.output / "sentinel").write_bytes(b"not ours")
            original(parent, stage, name)

        with patch.object(fixture, "_publish_noreplace", collide):
            with self.assertRaises(FileExistsError):
                self.run_acceptance()
        self.assertEqual((self.output / "sentinel").read_bytes(), b"not ours")
        self.assertEqual(list(self.tmp.iterdir()), [self.output])

    def test_binary_final_binding(self):
        final = dict(FINAL, storePath="/nix/store/foreign")
        with self.assertRaisesRegex(runner.Failure, "binary"):
            self.run_acceptance(final=final)
        self.assertEqual(self.calls, [])

    def test_invalid_spec_before_io(self):
        expected = copy.deepcopy(EXPECTED)
        expected["resourceManifest"]["resources"][0]["data_paths"] = ["/var/lib/real"]
        with self.assertRaisesRegex(runner.Failure, "owned"):
            self.run_acceptance(expected=expected)
        self.assertEqual(self.calls, [])
        self.assertEqual(list(self.tmp.iterdir()), [])

    def test_import_is_inert(self):
        spec = importlib.util.spec_from_file_location("inert_product_runner", runner.__file__)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertEqual(self.calls, [])
        self.assertEqual(list(self.tmp.iterdir()), [])

    def test_launch_failure_no_success_output(self):
        with patch.object(runner.subprocess, "Popen", side_effect=OSError("mock launch")):
            with self.assertRaisesRegex(OSError, "mock launch"):
                self.run_acceptance()
        self.assertFalse(os.path.lexists(self.output))
        self.assertEqual(list(self.tmp.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
