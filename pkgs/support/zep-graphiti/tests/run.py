"""Run lightweight and pinned real-client contracts in separate processes."""

from __future__ import annotations

import importlib.metadata
import os
from pathlib import Path
import subprocess
import sys


PACKAGE_DIR = Path(__file__).resolve().parents[1]


def main() -> int:
    # Fail rather than silently skip the real-client suite in a light environment.
    for line in (PACKAGE_DIR / "tests" / "requirements.txt").read_text().splitlines():
        requirement = line.partition("#")[0].strip()
        if not requirement:
            continue
        name, expected = requirement.split("==", 1)
        try:
            actual = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            actual = "not installed"
        if actual != expected:
            print(
                f"{name}: expected {expected}, got {actual}; install tests/requirements.txt",
                file=sys.stderr,
            )
            return 1

    environment = {**os.environ, "GRAPHITI_TELEMETRY_ENABLED": "false"}
    # The lightweight suite injects graphiti_core doubles into sys.modules.
    # Never discover both suites in the same interpreter.
    suites = (PACKAGE_DIR / "app" / "tests", PACKAGE_DIR / "tests")
    for suite in suites:
        result = subprocess.run(
            [sys.executable, "-B", "-m", "unittest", "discover", "-s", str(suite), "-v"],
            env=environment,
            check=False,
        )
        if result.returncode:
            return result.returncode
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
