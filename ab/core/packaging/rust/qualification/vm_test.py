"""NixOS test-driver script. Ordinary Nix only; no private-container receipts."""

import json
import os
import re
import shlex
import time
from pathlib import Path
from typing import Any


def quote(value):
    return shlex.quote(value)


observations: dict[str, Any] = {
    "schema": "rust-foundation-vm-matrix-v2",
    "status": "FAIL",
    "qualificationComplete": False,
    "cases": {},
}


def read_json(machine, command):
    return json.loads(machine.succeed(command))


def missing_outputs(machine, spec):
    outputs = set(spec["excludedOutputs"])
    for case in spec["cases"].values():
        outputs.update((case["buildOutput"], case["packageOutput"]))
    for case in spec["cases"].values():
        for key in ("buildDrv", "packageDrv"):
            machine.succeed("nix-store --check-validity " + quote(case[key]))
    for output in sorted(outputs):
        machine.succeed(f"test ! -e {quote(output)}")
    return len(outputs)


def run_case(machine, label, case, timeout, spec, mode="build"):
    started = time.monotonic()
    deadline = started + timeout
    result: dict[str, Any] = {
        "commands": [], "buildDrv": case["buildDrv"],
        "packageDrv": case["packageDrv"], "mode": mode,
    }
    observations["cases"][label] = result

    def execute(command):
        remaining = deadline - time.monotonic()
        assert remaining > 1, f"{label}: aggregate case deadline expired"
        code, stdout = machine.execute(command, timeout=max(1, int(remaining)))
        result["commands"].append({"exit": code, "command": command})
        if code != 0:
            # Failed outputs are not successful receipts. Retain diagnostics in
            # the normal build log even when output files are unavailable.
            _, diagnostic = machine.execute("tail -c 65536 " + quote(log), timeout=10)
            print(diagnostic)
        assert code == 0, f"{label}: command refused; see retained guest log"
        return stdout

    log = f"/tmp/{label}.log"
    result["status"] = "FAIL"
    try:
        outputs = sorted(set((case["buildOutput"], case["packageOutput"])))
        execute("touch " + quote(log))
        if mode == "cache-restore":
            # Only a guest-owned local cache is enabled in this transport case.
            # Build jobs and remote builders stay disabled during restoration.
            execute(
                "nix copy --to 'file:///tmp/rust-foundation-cache?compression=none' "
                + " ".join(map(quote, outputs)) + f" >>{quote(log)} 2>&1"
            )
        if mode in ("warm-recompile", "cache-restore"):
            # Remove only this disposable guest's tested outputs, keeping the
            # actual dependency bases. Ordinary Nix then reuses those bases.
            execute("nix-store --delete " + " ".join(map(quote, outputs)) + f" >>{quote(log)} 2>&1")
            for output in outputs:
                execute("test ! -e " + quote(output))
        targets = [case["buildDrv"] + "^out"]
        if mode != "determinism-rebuild" and case["packageDrv"] != case["buildDrv"]:
            targets.append(case["packageDrv"] + "^out")
        command = "nix build --no-link --print-build-logs "
        if mode == "cache-restore":
            command += "--max-jobs 0 --option builders '' --option substitute true --option require-sigs false --substituters file:///tmp/rust-foundation-cache "
        else:
            command += "--offline "
        if mode == "determinism-rebuild":
            command += "--rebuild "
        command += " ".join(map(quote, targets))
        execute(command + f" >>{quote(log)} 2>&1")
        if mode == "determinism-rebuild":
            execute("nix build --offline --no-link " + quote(case["packageDrv"] + "^out"))
        version = execute(quote(case["packageOutput"] + "/bin/" + case["mainProgram"]) + " --version")
        assert version == case["expectedVersion"], f"{label}: installed version mismatch"
        result["runtimeChecks"] = []
        for check in case["runtimeChecks"]:
            stdout = execute(
                quote(case["packageOutput"] + "/bin/" + case["mainProgram"])
                + " " + " ".join(map(quote, check["arguments"]))
            )
            assert stdout == check["expectedStdout"], f"{label}: runtime source-edit behavior mismatch"
            result["runtimeChecks"].append({"arguments": check["arguments"], "stdout": stdout})
        paths = execute(
            "nix path-info --offline --json "
            + " ".join(map(quote, sorted(set((case["buildOutput"], case["packageOutput"])))))
        )
        result["outputs"] = json.loads(paths)
        result["version"] = version
        result["status"] = "PASS"
        # Logs are evidence. We do not infer CargoFresh from a successful Nix exit.
        result["cargoFresh"] = "not_observed"
        return result
    finally:
        try:
            machine.copy_from_machine(log)
            result["logRetained"] = True
            with (Path(os.environ["out"]) / (label + ".log")).open("rb") as stream:
                body = stream.read(16 * 1024 * 1024 + 1)
            assert len(body) <= 16 * 1024 * 1024, "case build log exceeds 16MiB"
            text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", body.decode("utf-8", errors="replace"))
            compiled = re.findall(r"\bCompiling ([A-Za-z0-9_-]+) v[^\s]+", text)
            members = set(spec["workspaceCrates"])
            frontier = {
                "workspace": sorted(set(name for name in compiled if name in members)),
                "external": sorted(set(name for name in compiled if name not in members)),
                "externalCount": sum(name not in members for name in compiled),
                "totalCount": len(compiled),
            }
            result["compilationFrontier"] = frontier
            for key, expected in spec["expectedCompilations"].get(label, {}).items():
                assert frontier[key] == expected, f"{label}: unexpected compilation frontier {key}"
            if mode in ("cached", "cache-restore"):
                assert frontier["totalCount"] == 0, f"{label}: unexpected Cargo compilation on cache hit"
            result["frontierValidated"] = True
        except Exception:
            result.setdefault("logRetained", False)
            result["frontierValidated"] = False
            if result["status"] == "PASS":
                result["status"] = "FAIL"
                raise
        finally:
            result["elapsedSeconds"] = time.monotonic() - started


def nar_identity(result):
    rows = result["outputs"]
    if isinstance(rows, list):
        rows = {row["path"]: row for row in rows}
    return {path: {key: row[key] for key in ("narHash", "narSize", "references")} for path, row in rows.items()}

try:
    boot_started = time.monotonic()
    warm.start()
    machines = [warm] if comparison_only else [warm, fresh]
    if not comparison_only:
        fresh.start()
    for machine in machines:
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("nix-daemon.socket")
        machine.succeed("test -z \"$(ip -4 route show default)\"")
        config = read_json(machine, "nix config show --json")
        assert config["sandbox"]["value"] is True
        assert config["sandbox-fallback"]["value"] is False
        assert not config["substituters"]["value"]
        assert not config["builders"]["value"]
        assert config["allow-import-from-derivation"]["value"] is False
        machine.succeed("touch /etc/qualification-guest-marker")
    observations["bootSeconds"] = time.monotonic() - boot_started
    spec = read_json(warm, "cat /etc/rust-foundation-vm-spec.json")
    if not comparison_only:
        assert spec == read_json(fresh, "cat /etc/rust-foundation-vm-spec.json")
    if spec["recipeExpression"] is not None:
        for machine in machines:
            for name, case in spec["cases"].items():
                for attr, key in (("build", "buildDrv"), ("package", "packageDrv")):
                    actual = machine.succeed(
                        "nix-instantiate --option allow-import-from-derivation false "
                        + quote(spec["recipeExpression"]) + " -A " + quote(name + "." + attr)
                    ).strip()
                    assert actual == case[key], f"{name}: guest recipe identity differs"
    observations["seedAbsenceChecks"] = {
        machine.name: missing_outputs(machine, spec) for machine in machines
    }
    timeout = spec["buildTimeout"]
    observations["determinismRequired"] = spec["checkDeterminism"]
    if comparison_only:
        run_case(warm, "legacy-original", spec["cases"]["legacy"], timeout, spec)
        observations["scope"] = "legacy comparison only; no replay of required reuse cases"
    else:
        baseline = run_case(warm, "baseline", spec["cases"]["baseline"], timeout, spec)
        cached = run_case(warm, "unchanged-cached", spec["cases"]["baseline"], timeout, spec, mode="cached")
        assert nar_identity(baseline) == nar_identity(cached), "existing Nix cache hit changed registered outputs"
        restored = run_case(warm, "nix-cache-restored", spec["cases"]["baseline"], timeout, spec, mode="cache-restore")
        assert nar_identity(baseline) == nar_identity(restored), "Nix binary cache transport changed output identity"
        observations["nixCacheReuseValidated"] = True
        mode = "determinism-rebuild" if spec["checkDeterminism"] else "warm-recompile"
        unchanged = run_case(warm, "unchanged-warm", spec["cases"]["baseline"], timeout, spec, mode=mode)
        observations["unchangedWarmNarEqual"] = nar_identity(baseline) == nar_identity(unchanged)
        if spec["checkDeterminism"]:
            assert observations["unchangedWarmNarEqual"], "unchanged forced rebuild output metadata differs"
        changed_warm = run_case(warm, "changed-warm", spec["cases"]["changed"], timeout, spec)
        changed_fresh = run_case(fresh, "changed-fresh", spec["cases"]["changed"], timeout, spec)
        # narHash binds independently produced bytes; registration timestamps are not
        # part of deterministic output equality and may differ between guest stores.

        observations["changedWarmFreshNarEqual"] = nar_identity(changed_warm) == nar_identity(changed_fresh)
        observations["byteDeterminism"] = {
            "required": spec["checkDeterminism"],
            "status": "PASS" if observations["unchangedWarmNarEqual"] and observations["changedWarmFreshNarEqual"] else "FAIL",
        }
        if spec["checkDeterminism"]:
            assert observations["changedWarmFreshNarEqual"], "changed warm/fresh output bytes differ"
        observations["requiredReuseChecks"] = "PASS"
        if "legacy" in spec["cases"]:
            legacy = run_case(warm, "legacy-original", spec["cases"]["legacy"], timeout, spec)
            observations["costComparison"] = {
                "legacySeconds": legacy["elapsedSeconds"],
                "memberColdSeconds": baseline["elapsedSeconds"],
                "memberWarmSeconds": unchanged["elapsedSeconds"],
                "memberChangedWarmSeconds": changed_warm["elapsedSeconds"],
                "sourceEditRebuildSavingSeconds": legacy["elapsedSeconds"] - changed_warm["elapsedSeconds"],
                "scope": "selected real manager; complete workspace declarations/vendor; shared tool prerequisites; guest-local elapsed time",
            }
    observations["status"] = "PASS"
finally:
    # The framework owns guest cleanup. Failed cases stop; no retry loop or
    # per-command deadline reset. Preserve partial observations with normal logs.
    body = json.dumps(observations, sort_keys=True)
    assert len(body.encode()) <= 131072, "matrix report exceeds 128KiB"
    # Failed outputs may be unavailable; the normal build log persists.
    # Preserve the partial structured result there as well, without changing
    # the failing test's exit status or the first-refusal behavior.
    print("RUST_FOUNDATION_VM_RESULT " + body)
    output = Path(os.environ["out"]) / "matrix-observations.json"
    output.write_text(json.dumps(observations, indent=2, sort_keys=True) + "\n")
