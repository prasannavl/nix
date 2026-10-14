"""Non-native falsification tests. Every subprocess is mocked."""

import copy
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import fixture
import freshness as h


def artifact(name, features=(), fresh=True, executable=None):
    return {"reason": "compiler-artifact", "fresh": fresh, "features": list(features),
            "package_id": f"path+file:///fixture/members/{'leaf' if name == 'g4_leaf' else 'peer' if name == 'g4_peer' else 'app'}#0.1.0",
            "target": {"name": name, "kind": ["bin"] if name == "g4-app" else ["lib"]},
            "profile": {"test": False}, "executable": executable}


def messages(role="app", fresh=True, executable=None):
    if role == "peer":
        values = [artifact("g4_peer", fresh=fresh)]
    else:
        values = [artifact("g4_leaf", ("build", "macro"), fresh),
                  artifact("g4_leaf", ("normal", "dev") if role == "test" else ("normal",), fresh),
                  artifact("g4-app", fresh=fresh, executable=executable),
                  artifact("build-script-build", fresh=fresh),
                  {"reason": "build-script-executed", "package_id": "path+file:///fixture/members/app#0.1.0",
                   "env": [["G4_BUILD_MARKER", "input-v1:build+macro"]]}]
    if role != "peer":
        values[2]["profile"]["test"] = role == "test"
        values[3]["target"] = {"name": "build-script-build", "kind": ["custom-build"],
                               "src_path": "/fixture/members/app/build.rs"}
    return values + [{"reason": "build-finished", "success": True}]


def encode(values):
    return "".join(json.dumps(v) + "\n" for v in values)


class Observations(unittest.TestCase):
    def test_warm_and_roles(self):
        for role in ("app", "peer", "test"):
            h.observe(h.parse_messages(encode(messages(role))), role, warm=True)

    def test_fabricated_fresh_rust_edit(self):
        with self.assertRaisesRegex(h.Failure, "fabricated fresh"):
            h.observe(messages(), "app", rust_edit=True)

    def test_actual_dirty_rust_edit(self):
        h.observe(messages(fresh=False), "app", rust_edit=True)
        h.observe(messages("test", fresh=False), "test", rust_edit=True)
        h.observe(messages("peer"), "peer", rust_edit=True)

    def test_peer_locality(self):
        with self.assertRaisesRegex(h.Failure, "peer"):
            h.observe(messages("peer", fresh=False), "peer", rust_edit=True)

    def test_warm_nonfresh(self):
        with self.assertRaisesRegex(h.Failure, "nonfresh warm"):
            h.observe(messages(fresh=False), "app", warm=True)

    def test_feature_activation(self):
        values = messages()
        values[0]["features"].append("unused-local-probe")
        with self.assertRaisesRegex(h.Failure, "unused feature"):
            h.parse_messages(encode(values))

    def test_incorrect_feature_roles(self):
        values = messages()
        values[0]["features"] = ["normal", "build", "macro"]
        with self.assertRaisesRegex(h.Failure, "feature roles"):
            h.observe(values, "app")

    def test_missing_buildscript_effect(self):
        values = [m for m in messages() if m["reason"] != "build-script-executed"]
        with self.assertRaisesRegex(h.Failure, "effect missing"):
            h.observe(values, "app")

    def test_malformed_json(self):
        for text in ("not json\n", "[]\n", '{}\n', "\n", encode(messages()[:-1])):
            with self.subTest(text=text), self.assertRaises(h.Failure):
                h.parse_messages(text)

    def test_nonboolean_fresh(self):
        for value in (1, None, "true"):
            values = messages()
            values[0]["fresh"] = value
            with self.assertRaises(h.Failure):
                h.parse_messages(encode(values))


class Files(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=fixture.TMP_ROOT, prefix="freshness-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        for name, content in fixture.build_files().items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
            os.utime(path, ns=(1000000000, 1000000000))
        self.logs = self.root / "logs"
        self.logs.mkdir()
        self.lock = self.source / "Cargo.lock"

    def test_directory_and_file_type_errors(self):
        with self.assertRaises(h.Failure):
            h.regular(self.source)
        with self.assertRaises(h.Failure):
            h.directory(self.lock)
        link = self.root / "link"
        link.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(h.Failure):
            h.directory(link)
        (self.source / "foreign").symlink_to(self.lock)
        with self.assertRaises(h.Failure):
            h.tree_snapshot(self.source)

    def test_exact_deltas_and_unchanged_mtimes(self):
        for variant in fixture.VARIANTS:
            with self.subTest(variant=variant):
                before = h.tree_snapshot(self.source)
                delta = h.mutate(self.source, variant)
                expected = fixture.build_files(variant)
                self.assertEqual(set(delta), {n for n in expected
                    if expected[n] != fixture.build_files()[n]})
                for name in expected:
                    self.assertEqual((self.source / name).read_bytes(), expected[name])
                    if name not in delta:
                        self.assertEqual(before[name], h.tree_snapshot(self.source)[name])
                # Own copied fixture only; restore between unit cases.
                for name, content in fixture.build_files().items():
                    (self.source / name).write_bytes(content)
                    os.utime(self.source / name, ns=(1000000000, 1000000000))

    def test_lock_mutation_and_failure_attestation(self):
        def fake(argv, **kwargs):
            self.lock.write_text(self.lock.read_text() + "# unauthorized mutation\n")
            return subprocess.CompletedProcess(argv, 0, b"", b"diagnostic")
        runner = h.Runner(self.logs, {"PATH": "mock"}, self.lock)
        with patch.object(h.subprocess, "run", side_effect=fake) as mocked:
            with self.assertRaisesRegex(h.Failure, "full Cargo.lock changed"):
                runner.run(["mock-cargo"], self.source, cargo=True)
            self.assertEqual(mocked.call_count, 1)
        row = json.loads((self.logs / "001.json").read_text())
        self.assertFalse(row["lockInvariant"])
        self.assertNotEqual(row["lockBefore"], row["lockAfter"])
        self.assertEqual((self.logs / "001.stderr").read_bytes(), b"diagnostic")

    def test_nonzero_retains_logs(self):
        with patch.object(h.subprocess, "run", return_value=
                          subprocess.CompletedProcess([], 2, b"out", b"err")):
            with self.assertRaises(h.Failure):
                h.Runner(self.logs, {}, self.lock).run(["mock"], self.source, cargo=True)
        row = json.loads((self.logs / "001.json").read_text())
        self.assertTrue(row["lockInvariant"])
        self.assertEqual(row["exit"], 2)

    def test_process_exception_retains_attestation(self):
        with patch.object(h.subprocess, "run", side_effect=OSError("mock exception")):
            with self.assertRaises(OSError):
                h.Runner(self.logs, {}, self.lock).run(["mock"], self.source, cargo=True)
        self.assertTrue(json.loads((self.logs / "001.json").read_text())["lockInvariant"])

    def test_tar_rejects_traversal_links_devices(self):
        for name, kind in (("../escape", tarfile.REGTYPE), ("/escape", tarfile.REGTYPE),
                           ("release/link", tarfile.SYMTYPE), ("device", tarfile.CHRTYPE),
                           ("data/secrets/no.txt", tarfile.REGTYPE)):
            path = self.root / "bad.tar"
            with tarfile.open(path, "w") as archive:
                item = tarfile.TarInfo(name)
                item.type = kind
                archive.addfile(item)
            with self.subTest(name=name), self.assertRaises(h.Failure):
                h.inspect_tar(path)

    def test_foreign_executable(self):
        path = self.root / "exe"
        path.write_text("mock")
        path.chmod(0o700)
        target = self.root / "target"
        target.mkdir()
        with self.assertRaisesRegex(h.Failure, "foreign executable"):
            h.executable_path(str(path), target)

    def test_four_variant_cli_protocol_mock_only(self):
        # Readiness is separately tested against evaluated actual metadata below.
        # This synthetic fixture tests orchestration without store writes/builds.
        manifest = {"tools": {"cargo": str(self.lock), "rustc": str(self.lock),
                              "zstd": str(self.lock), "tar": str(self.lock)},
                    "environment": {"PATH": "mock"}, "restoration": {"chain": []},
                    "limits": {"exactProducer": "not_proven"}}
        before = h.tree_snapshot(self.source)
        output = self.root / "output"
        def fake(argv, cwd, env, **kwargs):
            if argv[0] == str(self.lock):
                self.assertTrue({"--release", "--offline", "--locked", "--jobs"} <= set(argv))
                self.assertEqual(argv[argv.index("--jobs") + 1], "1")
                role = "test" if argv[1] == "test" else (
                    "peer" if argv[argv.index("-p") + 1] == "g4-peer" else "app")
                executable = None
                if role != "peer":
                    exe = Path(env["CARGO_TARGET_DIR"]) / ("test-exe" if role == "test" else "app-exe")
                    exe.write_text("mock executable; never executed")
                    exe.chmod(0o700)
                    executable = str(exe)
                # Current step is determined by mock Cargo invocations, not wall time.
                phase_index = fake.count // 3 % 4
                fake.count += 1
                variant = Path(cwd).parent.name
                dirty = phase_index == 2 and variant == "rust-edit" and role != "peer"
                emitted = messages(role, fresh=not dirty, executable=executable)
                for event in emitted:
                    if "package_id" in event:
                        event["package_id"] = event["package_id"].replace("/fixture", str(cwd))
                    if "target" in event and "src_path" in event["target"]:
                        event["target"]["src_path"] = event["target"]["src_path"].replace("/fixture", str(cwd))
                stdout = encode(emitted).encode()
            elif argv[0].endswith("test-exe"):
                stdout = b"test result: ok. 1 passed; 0 failed\n"
            else:
                stdout = (Path(cwd) / "expected-output.txt").read_bytes()
            return subprocess.CompletedProcess(argv, 0, stdout, b"mock stderr")
        fake.count = 0
        with patch.object(h, "validate_manifest", return_value=(self.source, before, {})), \
                patch.object(h.subprocess, "run", side_effect=fake) as mocked:
            summary = h.execute(manifest, output)
        self.assertEqual(summary["status"], "passed")
        self.assertEqual(set(summary["variants"]), set(fixture.VARIANTS))
        self.assertEqual(fake.count, 48)
        self.assertEqual(mocked.call_count, 80)
        self.assertEqual(h.tree_snapshot(self.source), before)
        for record in output.glob("*/logs/[0-9]*.json"):
            self.assertTrue(json.loads(record.read_text())["lockInvariant"])
        self.assertTrue(summary["immutableOriginals"])


class BoundManifest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(dir=fixture.TMP_ROOT, prefix="freshness-manifest-")
        self.addCleanup(temp.cleanup)
        source = Path(temp.name)
        for name, content in fixture.build_files().items():
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        # Synthetic malformed-manifest controls, never an admission certificate.
        handle = {"derivationPath": "/nix/store/00000000000000000000000000000000-mock-seed.drv", "output": "out",
                  "storePath": "/nix/store/00000000000000000000000000000000-mock-seed"}
        self.actual = {"schemaVersion": 1, "source": str(source),
                       "seed": {"handle": handle, "archive": handle["storePath"] + "/target.tar.zst",
                                "recipe": {"projectDir": "members/app"},
                                "admission": {"kind": "actual-constructor-reconstruction",
                                              "consumer": copy.deepcopy(handle),
                                              "cargoArtifacts": copy.deepcopy(handle)}},
                       "limits": {"exactProducer": "not_proven"}}

    def test_archive_identity_falsification(self):
        value = copy.deepcopy(self.actual)
        value["seed"]["archive"] = "/nix/store/foreign/target.tar.zst"
        with self.assertRaisesRegex(h.Failure, "seed archive identity"):
            h.validate_manifest(value)

    def test_admission_identity_falsification(self):
        self.assertIsNotNone(self.actual)
        value = copy.deepcopy(self.actual)
        value["seed"]["admission"]["cargoArtifacts"]["storePath"] = "/nix/store/11111111111111111111111111111111-foreign"
        with self.assertRaisesRegex(h.Failure, "admitted artifact mismatch"):
            h.validate_manifest(value)

    def test_producer_claim_falsification(self):
        self.assertIsNotNone(self.actual)
        value = copy.deepcopy(self.actual)
        value["limits"]["exactProducer"] = "qualified"
        with self.assertRaisesRegex(h.Failure, "producer scope"):
            h.validate_manifest(value)


class ReviewFalsifiers(unittest.TestCase):
    def test_identity_traversal_and_malformed_roots(self):
        valid = "/nix/store/" + "0" * 32 + "-seed"
        for bad in ("/nix/store/../../tmp/foreign", valid + "/child", valid + "/.",
                    valid + "/../escape", valid.replace("/store/", "/store//"),
                    "/nix/store/short-seed", "/nix/store/" + "e" * 32 + "-seed"):
            with self.subTest(path=bad), self.assertRaises(h.Failure):
                h.identity({"derivationPath": valid + ".drv", "output": "out", "storePath": bad})

    def test_tool_traversal_and_resolved_escape(self):
        valid = "/nix/store/" + "0" * 32 + "-tools/bin/cargo"
        with self.assertRaises(h.Failure):
            h.resolved_store_path(valid + "/../../../../tmp/escape")
        with patch.object(Path, "resolve", return_value=Path("/tmp/escape")):
            with self.assertRaisesRegex(h.Failure, "noncanonical store"):
                h.resolved_store_path(valid)
        other = Path("/nix/store/" + "1" * 32 + "-cargo/bin/cargo")
        with patch.object(Path, "resolve", return_value=other):
            self.assertEqual(h.resolved_store_path(valid), other)

    def bindings(self):
        handle = {"derivationPath": "/nix/store/" + "0" * 32 + "-seed.drv",
                  "storePath": "/nix/store/" + "1" * 32 + "-seed", "output": "out"}
        hook = {"derivationPath": "/nix/store/" + "2" * 32 + "-hook.drv",
                "storePath": "/nix/store/" + "3" * 32 + "-hook", "output": "out"}
        return {"recipes": {"seed": {"buildPhase": "actual seed"}},
                "recipeAnchors": {handle["derivationPath"]: {"handle": handle,
                    "contextualRecipe": {"buildPhase": "actual seed"}},
                    hook["derivationPath"]: {"handle": hook, "contextualRecipe": {"builder": "actual hook"}}},
                "restoration": {"chain": [{"handle": handle, "contextualRecipe": {"buildPhase": "actual seed"}}],
                                "hook": hook, "hookRecipe": {"builder": "actual hook"}}}

    def test_archive_recipe_tampering_stable_identity(self):
        value = self.bindings()
        h.validate_recipe_bindings(value)
        value["restoration"]["chain"][0]["contextualRecipe"]["buildPhase"] = "foreign recipe"
        with self.assertRaisesRegex(h.Failure, "archive contextual recipe mismatch"):
            h.validate_recipe_bindings(value)

    def test_hook_recipe_tampering_stable_identity(self):
        value = self.bindings()
        value["restoration"]["hookRecipe"]["builder"] = "foreign hook"
        with self.assertRaisesRegex(h.Failure, "hook contextual recipe mismatch"):
            h.validate_recipe_bindings(value)

    def test_seed_recipe_mismatch(self):
        value = self.bindings()
        value["recipes"]["seed"] = {"buildPhase": "wrong seed"}
        with self.assertRaisesRegex(h.Failure, "seed contextual recipe mismatch"):
            h.validate_recipe_bindings(value)

    def test_foreign_missing_malformed_effect_package(self):
        for package in (None, 1, "path+file:///foreign-peer#0.1.0",
                        "path+file:///fixture/members/peer#0.1.0"):
            values = messages()
            values[4]["package_id"] = package
            with self.subTest(package=package), self.assertRaises(h.Failure):
                h.observe(values, "app")

    def test_duplicate_missing_wrongrole_artifacts_effects(self):
        for case in ("duplicate-effect", "missing-script", "foreign-script", "wrong-role", "duplicate-leaf"):
            values = messages()
            if case == "duplicate-effect": values.insert(4, copy.deepcopy(values[4]))
            if case == "missing-script": del values[3]
            if case == "foreign-script": values[3]["package_id"] = "path+file:///foreign#0.1.0"
            if case == "wrong-role": values[2]["profile"]["test"] = True
            if case == "duplicate-leaf": values.insert(0, copy.deepcopy(values[0]))
            with self.subTest(case=case), self.assertRaises(h.Failure):
                h.observe(values, "app")

if __name__ == "__main__":
    unittest.main()
