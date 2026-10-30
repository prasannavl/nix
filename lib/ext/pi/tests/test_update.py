"""Offline Pi updater contracts; no registry, user state or package activation."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "update.sh"
DEFINITIONS = SCRIPT.read_text().rsplit('\nmain "$@"', 1)[0]
HASH = "sha256-" + "A" * 43 + "="


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="pi-update-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def shell(self, body, *, ok=True, env=None):
        setup = f"""
shopt -s inherit_errexit
RUNTIME_DIR={shlex.quote(str(self.root))}
STAGING_DIR="$RUNTIME_DIR"
WORKING_SOURCES="$RUNTIME_DIR/sources.json"
SOURCES_JSON='{{"sample":{{"package":"sample"}}}}'
TARGET_OS=linux
TARGET_CPU=x64
TARGET_LIBC=glibc
ALL_PACKAGES=(sample)
"""
        result = subprocess.run(
            ["bash", "-c", DEFINITIONS + setup + body],
            capture_output=True,
            text=True,
            env={**os.environ, **(env or {})},
            timeout=30,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def graph(self, manifests, ranges, *, ok=True, extra=""):
        fixture = self.root / "graph.json"
        fixture.write_text(json.dumps({"manifests": manifests, "ranges": ranges}))
        return self.shell(
            """
npm_manifest() { jq -cer --arg key "$1" '.manifests[$key] // empty' "$FIXTURE"; }
resolve_range_version() { jq -er --arg key "$1@$2" '.ranges[$key] // empty' "$FIXTURE"; }
prefetch_unpack_hash() { printf '%s\n' "$HASH"; }
"""
            + extra
            + '\nresult="$(resolve_deps sample 1.0.0)"\njq -c . "$result"\n',
            ok=ok,
            env={"FIXTURE": str(fixture), "HASH": HASH},
        )

    @staticmethod
    def manifest(**kwargs):
        return {"dist": {"tarball": "https://example.invalid/package.tgz"}, **kwargs}

    def test_transitive_cycle_and_host_modules(self):
        root = self.manifest(
            dependencies={
                "a": "^1",
                "@earendil-works/pi-ai": "*",
                "@mariozechner/pi-tui": "*",
                "typebox": "*",
                "@sinclair/typebox": "*",
                "@earendil-works/other": "1",
            }
        )
        result = self.graph(
            {
                "sample@1.0.0": root,
                "a@1.0.0": self.manifest(dependencies={"b": "1"}),
                "b@1.0.0": self.manifest(dependencies={"a": "^1"}),
                "@earendil-works/other@1.0.0": self.manifest(),
            },
            {"a@^1": "1.0.0", "b@1": "1.0.0", "@earendil-works/other@1": "1.0.0"},
        )
        self.assertEqual(
            set(json.loads(result.stdout)), {"a", "b", "@earendil-works/other"}
        )

    def test_flat_version_conflict_fails(self):
        result = self.graph(
            {
                "sample@1.0.0": self.manifest(dependencies={"a": "1", "b": "1"}),
                "a@1.0.0": self.manifest(),
                "b@1.0.0": self.manifest(dependencies={"a": "2"}),
            },
            {"a@1": "1.0.0", "b@1": "1.0.0", "a@2": "2.0.0"},
            ok=False,
        )
        self.assertIn("flat node_modules", result.stderr)

    def test_missing_required_range_fails(self):
        result = self.graph(
            {"sample@1.0.0": self.manifest(dependencies={"a": "1"})}, {}, ok=False
        )
        self.assertIn("No published a", result.stderr)

    def test_required_metadata_failure_fails(self):
        result = self.graph(
            {"sample@1.0.0": self.manifest(dependencies={"a": "1"})},
            {"a@1": "1.0.0"},
            ok=False,
        )
        self.assertIn("Could not read npm metadata", result.stderr)

    def test_hash_failure_fails(self):
        result = self.graph(
            {
                "sample@1.0.0": self.manifest(dependencies={"a": "1"}),
                "a@1.0.0": self.manifest(),
            },
            {"a@1": "1.0.0"},
            ok=False,
            extra="prefetch_unpack_hash() { return 17; }",
        )
        self.assertIn("Could not hash", result.stderr)

    def test_empty_hash_fails(self):
        result = self.graph(
            {
                "sample@1.0.0": self.manifest(dependencies={"a": "1"}),
                "a@1.0.0": self.manifest(),
            },
            {"a@1": "1.0.0"},
            ok=False,
            extra="prefetch_unpack_hash() { :; }",
        )
        self.assertIn("Empty hash", result.stderr)

    def test_malformed_dependencies_fail(self):
        self.graph({"sample@1.0.0": {"dependencies": {"a": None}}}, {}, ok=False)
        self.graph({"sample@1.0.0": {"optionalDependencies": {"a": 42}}}, {}, ok=False)

    def test_optional_overrides_required_and_missing_optional_is_skipped(self):
        result = self.graph(
            {
                "sample@1.0.0": self.manifest(
                    dependencies={"native": "1"},
                    optionalDependencies={"native": "2", "absent": "1"},
                ),
                "native@2.0.0": self.manifest(os=["darwin"]),
            },
            {"native@2": "2.0.0"},
        )
        self.assertEqual(json.loads(result.stdout), {})

    def test_optional_platform_matrix(self):
        cases = [
            ("pkg", {"cpu": ["x64"]}, "linux", "x64", "glibc", True),
            ("pkg", {"cpu": ["arm64"]}, "linux", "x64", "glibc", False),
            (
                "pkg",
                {"os": ["!win32"], "cpu": ["!ia32"]},
                "linux",
                "x64",
                "glibc",
                True,
            ),
            ("pkg", {"os": ["linux", "!linux"]}, "linux", "x64", "glibc", False),
            ("pkg", {"os": "any"}, "darwin", "arm64", "glibc", True),
            ("pkg", {"os": "linux", "libc": ["!musl"]}, "linux", "x64", "musl", False),
            ("sherpa-onnx-linux-x64", {}, "linux", "x64", "glibc", True),
            ("sherpa-onnx-linux-arm64", {}, "linux", "x64", "glibc", False),
            ("sherpa-onnx-linux-arm64", {}, "linux", "arm64", "glibc", True),
            ("sherpa-onnx-darwin-arm64", {}, "darwin", "arm64", "glibc", True),
            ("@decibri/decibri-linux-x64-musl", {}, "linux", "x64", "glibc", False),
            ("@decibri/decibri-linux-x64-musl", {}, "linux", "x64", "musl", True),
            ("@decibri/decibri-linux-x64-gnu", {}, "linux", "x64", "musl", False),
            ("pkg", {"cpu": 42}, "linux", "x64", "glibc", False),
        ]
        for name, manifest, target_os, cpu, libc, expected in cases:
            with self.subTest(name=name, manifest=manifest, target=cpu):
                body = f"""
TARGET_OS={target_os}; TARGET_CPU={cpu}; TARGET_LIBC={libc}
if dep_supports_platform {shlex.quote(name)} {shlex.quote(json.dumps(manifest))}; then echo yes; else echo no; fi
"""
                self.assertEqual(
                    self.shell(body).stdout.strip(), "yes" if expected else "no"
                )

    def test_queue_is_fresh_for_each_resolution(self):
        result = self.shell("""
npm_manifest() { echo '{}'; }
DEP_NAMES=(stale); DEP_RANGES=(bad)
resolve_range_version() { return 1; }
resolve_deps sample 1.0.0 >/dev/null
resolve_deps sample 1.0.0 >/dev/null
""")
        self.assertEqual(result.stdout, "")

    def test_renderer_preserves_empty_deps_and_literal_interpolation(self):
        source = {
            "sample": {
                "kind": "npm",
                "package": "sample",
                "version": "1.0.0",
                "srcHash": HASH,
                "depsResolver": "registry",
                "deps": {},
            },
            "retained": {
                "kind": "npm",
                "package": '${builtins.throw "unsafe"}',
                "version": "1.0.0",
                "srcHash": HASH,
                "deps": {
                    "dep": {
                        "kind": "npm-dep",
                        "range": '${builtins.throw "unsafe"}',
                        "version": "1.0.0",
                        "srcHash": HASH,
                    }
                },
            },
        }
        (self.root / "sources.json").write_text(json.dumps(source))
        self.shell(
            'ALL_PACKAGES=(sample retained)\nrender_sources > "$RUNTIME_DIR/rendered.nix"\n'
        )
        rendered = subprocess.check_output(
            [
                "nix",
                "--offline",
                "eval",
                "--json",
                "--file",
                str(self.root / "rendered.nix"),
            ],
            text=True,
        )
        self.assertEqual(json.loads(rendered), source)

    def test_non_https_source_rejected_before_fetch(self):
        result = self.shell(
            "nix() { echo unexpected-fetch >&2; exit 92; }\nprefetch_unpack_hash file:///not-read",
            ok=False,
        )
        self.assertIn("Expected HTTPS", result.stderr)
        self.assertNotIn("unexpected-fetch", result.stderr)

    def test_new_catalog_package_dispatch_and_transaction_failure(self):
        original = {
            "sample": {
                "kind": "npm",
                "package": "sample",
                "version": "1.0.0",
                "srcHash": HASH,
                "depsResolver": "registry",
                "deps": {},
            }
        }
        source_file = self.root / "installed.nix"
        source_file.write_text("unchanged original\n")
        (self.root / "sources.json").write_text(json.dumps(original))
        result = self.shell(
            """
SOURCES_JSON="$(<"$WORKING_SOURCES")"
REQUESTED_VERSION=''; FORCE=1; CHANGED=0; COLOR_MODE=never
SOURCES_FILE="$RUNTIME_DIR/installed.nix"
resolve_metadata() { echo '{"version":"2.0.0","dist":{"tarball":"https://example.invalid/test.tgz"}}'; }
prefetch_unpack_hash() { echo "$HASH"; }
write_staged_sources() { render_sources > "$STAGING_DIR/sources.nix"; }
npm_manifest() { echo '{"dependencies":{"missing":"1"}}'; }
resolve_range_version() { return 1; }
build_package() { echo unexpected-build >&2; }
update_package sample
install_sources
""",
            ok=False,
            env={"HASH": HASH},
        )
        self.assertIn("No published missing", result.stderr)
        self.assertNotIn("unexpected-build", result.stderr)
        self.assertEqual(source_file.read_text(), "unchanged original\n")

    def test_new_catalog_package_success(self):
        data = {
            "extra-package": {
                "kind": "npm",
                "package": "extra-package",
                "version": "1.0.0",
                "srcHash": HASH,
            }
        }
        (self.root / "sources.json").write_text(json.dumps(data))
        self.shell(
            """
SOURCES_JSON="$(<"$WORKING_SOURCES")"
mapfile -t ALL_PACKAGES < <(jq -r 'keys[]' <<<"$SOURCES_JSON")
REQUESTED_PACKAGES=(); REQUESTED_VERSION=''; FORCE=0; REPORT=0; COLOR_MODE=never; CHANGED=0
validate_options
[[ "${REQUESTED_PACKAGES[*]}" == extra-package ]]
resolve_metadata() { echo '{"version":"2.0.0","dist":{"tarball":"https://example.invalid/test.tgz"}}'; }
prefetch_unpack_hash() { echo "$HASH"; }
write_staged_sources() { render_sources > "$STAGING_DIR/sources.nix"; }
build_package() { nix --offline eval --json --file "$STAGING_DIR/sources.nix" > "$RUNTIME_DIR/built.json"; }
update_package extra-package
[[ "$CHANGED" == 1 ]]
""",
            env={"HASH": HASH},
        )
        built = json.loads((self.root / "built.json").read_text())
        self.assertEqual(built["extra-package"]["version"], "2.0.0")

    def test_main_discovers_catalog_and_report_stays_read_only(self):
        catalog = self.root / "catalog.nix"
        catalog.write_text(
            '{ extra-package = {package = "extra-package"; version = "1.0.0";}; }'
        )
        result = self.shell("""
ensure_runtime_shell() { :; }
init_vars() {
  SOURCES_FILE="$RUNTIME_DIR/catalog.nix"
  REQUESTED_PACKAGES=(); ALL_PACKAGES=(); REQUESTED_VERSION=''
  REPORT=0; FORCE=0; COLOR_MODE=never
}
init_runtime() { :; }
cleanup() { :; }
init_staging() { echo unexpected-staging >&2; exit 91; }
resolve_metadata() { echo '{"version":"2.0.0"}'; }
main --report --package extra-package
""")
        self.assertIn("extra-package: 1.0.0 -> 2.0.0", result.stdout)
        self.assertNotIn("unexpected-staging", result.stderr)
        self.assertEqual(
            catalog.read_text(),
            '{ extra-package = {package = "extra-package"; version = "1.0.0";}; }',
        )

    def test_unchanged_version_does_not_build_or_write(self):
        result = self.shell("""
SOURCES_JSON='{"sample":{"package":"sample","version":"1.0.0"}}'
FORCE=0
resolve_metadata() { echo '{"version":"1.0.0"}'; }
set_source_record() { exit 92; }
build_package() { exit 93; }
update_package sample
""")
        self.assertIn("skipping", result.stdout)


if __name__ == "__main__":
    unittest.main()
