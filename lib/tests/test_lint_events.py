import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

LINT = Path(os.environ["LINT_SCRIPT"]).read_text()
TREEFMT = Path(os.environ["TREEFMT_CONFIG"]).read_text()
MARKDOWNLINT = Path(os.environ["MARKDOWNLINT_CONFIG"])
long = "# Evidence\n\n" + " ".join(["original append-only evidence"] * 12) + "\n"
clean = "# Notes\n\nValid paragraph.\n"
event_path = ".agents/plans/work/format-fixture/events/0001-raw.md"
ordinary_path = ".agents/docs/events/normal note.md"
results = []


def source(kind, old, source_glob=False):
    value = LINT if kind == "scripts/lint.sh" else TREEFMT
    if source_glob and kind == "scripts/lint.sh":
        assert value.count(" | exclude_plan_events") == 1
        value = value.replace(" | exclude_plan_events", "")
        value = value.replace(
            "deno fmt --check --permit-no-files",
            "deno fmt --check --permit-no-files --ignore='.agents/plans/**/events/**'",
        )
    if old:
        fragments = (
            (
                " '#.agents/plans/**/events/**'",
                " | exclude_plan_events",
            )
            if kind == "scripts/lint.sh"
            else ('excludes = [".agents/plans/**/events/**"]\n',)
        )
        for fragment in fragments:
            assert value.count(fragment) == 1, (kind, fragment)
            value = value.replace(fragment, "")
    return value


def run_case(
    label,
    *,
    old=False,
    source_glob=False,
    fix=False,
    event=long,
    ordinary=clean,
    event_only=False,
):
    with tempfile.TemporaryDirectory(prefix="lint-events-") as temporary:
        root = Path(temporary)
        for p in [
            "scripts",
            "tf",
            str(Path(event_path).parent),
            str(Path(ordinary_path).parent),
            "cache",
        ]:
            (root / p).mkdir(parents=True, exist_ok=True)
        (root / event_path).write_text(event)
        (root / ordinary_path).write_text(ordinary)
        raw = root / ".agents/docs/unchanged.md.raw"
        raw.write_text("raw    bytes  \n")
        (root / ".markdownlint-cli2.jsonc").write_bytes(MARKDOWNLINT.read_bytes())
        (root / "treefmt.toml").write_text(source("treefmt.toml", old))
        script = source("scripts/lint.sh", old, source_glob)
        assert script.endswith('main "$@"\n')
        (root / "lint-functions.sh").write_text(script.removesuffix('main "$@"\n'))
        (root / "scripts/fmt.sh").write_text(
            'set -Eeuo pipefail\nexec treefmt --tree-root "$PWD" --config-file "$PWD/treefmt.toml" --formatters deno\n'
        )
        subprocess.run(["git", "init", "--quiet", str(root)], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(root),
                "add",
                "--",
                event_path,
                ordinary_path,
                str(raw.relative_to(root)),
                ".markdownlint-cli2.jsonc",
                "treefmt.toml",
            ],
            check=True,
        )
        harness = f"""source ./lint-functions.sh
REPO_ROOT={shlex.quote(str(root))}
LINT_FIX={int(fix)}
LINT_MODE=full
PROJECT_NAMES=()
CURRENT_STEP=""
CURRENT_STEP_DESCRIPTION=""
ensure_runtime_tools() {{ for c in deno markdownlint-cli2 treefmt; do command -v "$c" >/dev/null; done; }}
lint_scope() {{ printf full; }}
collect_all_package_paths() {{ :; }}
check_self_reference_fetcher() {{ :; }}
actionlint() {{ :; }}
run_root_flake_check() {{ :; }}
collect_root_files() {{
  if [ "$1" = '*.md' ]; then
    {":" if event_only else "printf '%s\\0' " + shlex.quote(ordinary_path)}
    printf '%s\\0' {shlex.quote(event_path)}
  fi
}}
run_lint_action
"""
        real_deno = shutil.which("deno")
        assert real_deno
        argv_log = root / "deno-argv.jsonl"
        (root / "bin").mkdir()
        wrapper = root / "bin/deno"
        wrapper.write_text(
            f"#!{sys.executable}\n"
            "import json, os, sys\n"
            f"with open({str(argv_log)!r}, 'a') as output:\n"
            "    output.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            f"os.execv({real_deno!r}, [{real_deno!r}, *sys.argv[1:]])\n"
        )
        wrapper.chmod(0o755)
        env = {
            **os.environ,
            "PATH": str(root / "bin") + os.pathsep + os.environ["PATH"],
            "HOME": str(root / "home"),
            "XDG_CACHE_HOME": str(root / "cache"),
            "DENO_NO_UPDATE_CHECK": "1",
        }
        result = subprocess.run(
            ["bash", "-c", harness],
            cwd=root,
            env=env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        calls = (
            [json.loads(line) for line in argv_log.read_text().splitlines()]
            if argv_log.exists()
            else []
        )
        record = {
            "case": label,
            "eventPassedToDeno": any(
                arg == event_path or arg.endswith("/" + event_path)
                for call in calls
                for arg in call
            ),
            "status": result.returncode,
            "eventUnchanged": (root / event_path).read_text() == event,
            "ordinaryUnchanged": (root / ordinary_path).read_text() == ordinary,
            "rawUnchanged": raw.read_text() == "raw    bytes  \n",
        }
        assert record["rawUnchanged"], record
        results.append(record)
        return record, result.stdout


r, log = run_case("current-fix", fix=True, ordinary=long)
assert r["status"] == 0 and r["eventUnchanged"] and not r["ordinaryUnchanged"], (r, log)
assert not r["eventPassedToDeno"], (r, log)
r, log = run_case("old-fix", old=True, fix=True, ordinary=long)
assert r["status"] == 0 and not r["eventUnchanged"] and not r["ordinaryUnchanged"], (
    r,
    log,
)
r, log = run_case("current-mixed-order")
assert r["status"] == 0 and r["eventUnchanged"] and not r["eventPassedToDeno"], (r, log)
r, log = run_case("source-glob-argument-leak", source_glob=True)
# Enforce the boundary even where Deno happens to honor its glob.
assert r["eventPassedToDeno"] and r["eventUnchanged"] and "deno-fmt-check" in log, (
    r,
    log,
)
r, log = run_case("current-event-only", event_only=True)
assert r["status"] == 0 and r["eventUnchanged"], (r, log)
r, log = run_case("old-event-only", old=True, event_only=True)
assert r["status"] != 0 and "deno-fmt-check" in log, (r, log)
r, log = run_case("current-normal-drift", ordinary=long)
assert r["status"] != 0 and "deno-fmt-check" in log and r["ordinaryUnchanged"], (r, log)
bad = "# Evidence\n\nTrailing whitespace.   \n"
r, log = run_case("current-read-only-event-lint", fix=True, event=bad, event_only=True)
assert r["status"] != 0 and r["eventUnchanged"] and "MD009" in log, (r, log)
with tempfile.TemporaryDirectory(prefix="lint-event-paths-") as temporary:
    functions = Path(temporary) / "lint-functions.sh"
    functions.write_text(LINT.removesuffix('main "$@"\n'))
    kept = [
        ordinary_path,
        ".agents/docs/line\nbreak.md",
        ".agents/plans/work/fixture/events.md",
    ]
    excluded = [event_path, ".agents/plans/events/root.json"]
    payload = b"\0".join(p.encode() for p in kept + excluded) + b"\0"
    filtered = subprocess.run(
        ["bash", "-c", 'source "$1"; exclude_plan_events', "_", str(functions)],
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    assert filtered.stdout == b"\0".join(p.encode() for p in kept) + b"\0", filtered
results.append({"case": "nul-path-boundaries", "status": 0})
print(json.dumps(results, indent=2))
print("NINE_LINT_EVENT_POLICY_CASES_PASS")
