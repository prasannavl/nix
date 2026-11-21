"""Real-tool Markdown policy, independent of repository identity or event layout."""

import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path


LINT = Path(os.environ["LINT_SCRIPT"]).read_text()
FMT = Path(os.environ["FMT_SCRIPT"]).read_text()
TREEFMT = Path(os.environ["TREEFMT_CONFIG"]).read_text()
MARKDOWNLINT = Path(os.environ["MARKDOWNLINT_CONFIG"]).read_bytes()
MARKDOWN = (
    ".agents/docs/normal note.md",
    ".agents/plans/work/fixture/events/0001-entry.md",
    ".agents/plans/events/0001-root.md",
)
JSON_PATH = ".agents/plans/work/fixture/events/0002-state.json"
CLEAN = "# Notes\n\nValid paragraph.\n"
DRIFT = (
    "# Notes\n\n"
    + " ".join(["Formatting applies to every Markdown document."] * 12)
    + "\n"
)


class MarkdownPolicyTests(unittest.TestCase):
    def run_case(self, *, changed=None, fix=False):
        with tempfile.TemporaryDirectory(prefix="lint-markdown-") as temporary:
            root = Path(temporary)
            files = {path: CLEAN for path in MARKDOWN}
            files[JSON_PATH] = '{ "ready": true }\n'
            # Obtain canonical JSON from the same pinned tool as production.
            canonical = subprocess.run(
                ["deno", "fmt", "--ext=json", "-"],
                input=files[JSON_PATH],
                text=True,
                capture_output=True,
                check=True,
            ).stdout
            files[JSON_PATH] = canonical
            files.update(changed or {})
            for name, content in files.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
            raw = root / ".agents/docs/evidence.md.raw"
            raw.write_bytes(b"Original    raw bytes  \n")
            (root / "scripts").mkdir()
            (root / "scripts/fmt.sh").write_text(FMT)
            (root / "treefmt.toml").write_text(TREEFMT)
            (root / ".markdownlint-cli2.jsonc").write_bytes(MARKDOWNLINT)
            (root / ".gitignore").write_text("/cache/\n/home/\n")
            (root / "tf").mkdir()
            assert LINT.endswith('main "$@"\n')
            (root / "lint-functions.sh").write_text(LINT.removesuffix('main "$@"\n'))
            env = {
                key: value
                for key, value in os.environ.items()
                if not key.startswith("GIT_")
            }
            env.update(
                {
                    "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_CONFIG_GLOBAL": "/dev/null",
                    "HOME": str(root / "home"),
                    "XDG_CACHE_HOME": str(root / "cache"),
                    "DENO_NO_UPDATE_CHECK": "1",
                    "FMT_IN_NIX_SHELL": "1",
                    "PKG_OPS_MANIFEST": "",
                }
            )
            subprocess.run(["git", "init", "--quiet", str(root)], env=env, check=True)
            subprocess.run(
                ["git", "-C", str(root), "add", "--", *files], env=env, check=True
            )
            md_args = " ".join(shlex.quote(path) for path in MARKDOWN)
            harness = f"""source ./lint-functions.sh
REPO_ROOT={shlex.quote(str(root))}
LINT_FIX={int(fix)}
LINT_MODE=full
PROJECT_NAMES=()
CURRENT_STEP=""
CURRENT_STEP_DESCRIPTION=""
ensure_runtime_tools() {{ for tool in deno markdownlint-cli2 treefmt; do command -v "$tool" >/dev/null; done; }}
lint_scope() {{ printf full; }}
collect_all_package_paths() {{ :; }}
check_self_reference_fetcher() {{ :; }}
actionlint() {{ :; }}
run_root_flake_check() {{ :; }}
collect_root_files() {{
  if [ "$1" = '*.md' ]; then
    printf '%s\\0' {md_args}
    if [ "$#" -gt 1 ]; then printf '%s\\0' {shlex.quote(JSON_PATH)}; fi
  fi
}}
run_lint_action
"""
            result = subprocess.run(
                ["bash", "-c", harness],
                cwd=root,
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            after = {name: (root / name).read_text() for name in files}
            self.assertEqual(raw.read_bytes(), b"Original    raw bytes  \n")
            if not fix:
                self.assertEqual(after, files, result.stdout)
            if result.returncode == 0:
                subprocess.run(
                    ["deno", "fmt", "--check", *files],
                    cwd=root,
                    env=env,
                    check=True,
                    capture_output=True,
                )
            return result, files, after

    def test_formatted_documents_pass(self):
        result, _, _ = self.run_case()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_all_markdown_drift_is_rejected_without_mutation(self):
        for path in MARKDOWN:
            with self.subTest(path=path):
                result, _, _ = self.run_case(changed={path: DRIFT})
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("deno-fmt-check", result.stdout)

    def test_fix_includes_events_and_json(self):
        changed = {path: DRIFT for path in MARKDOWN}
        changed[JSON_PATH] = '{"ready":true}'
        result, before, after = self.run_case(changed=changed, fix=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        for path in changed:
            with self.subTest(path=path):
                self.assertNotEqual(before[path], after[path])

    def test_markdown_lint_also_applies_to_events(self):
        for fix in (False, True):
            with self.subTest(fix=fix):
                result, _, _ = self.run_case(
                    changed={MARKDOWN[1]: "# Notes\n\n### Skipped level\n"},
                    fix=fix,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("MD001", result.stdout)


if __name__ == "__main__":
    unittest.main()
