#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path


def write_log(args):
    log_path = os.environ.get("TEST_INCUS_LOG")
    if log_path:
        with Path(log_path).open("a", encoding="utf-8") as log:
            log.write(json.dumps(args) + "\n")


def should_fail(args):
    for prefix in json.loads(os.environ.get("TEST_INCUS_FAIL_PREFIXES", "[]")):
        if args[: len(prefix)] == prefix:
            return True
    return False


def main():
    args = sys.argv[1:]
    write_log(args)

    if should_fail(args):
        print(os.environ.get("TEST_INCUS_FAIL_MESSAGE", "fake incus failure"), file=sys.stderr)
        return 1

    if not args:
        return 0

    if args[0] == "info":
        return 0

    if args[:2] in (["remote", "add"], ["remote", "switch"]):
        return 0

    if args[0] == "query":
        print(os.environ.get("TEST_INCUS_QUERY_JSON", "{}"))
        return 0

    if args[0] == "list":
        if "--all-projects" in args:
            print(os.environ.get("TEST_INCUS_LIST_ALL_JSON", "[]"))
        else:
            print(os.environ.get("TEST_INCUS_PROJECT_LIST_JSON", "[]"))
        return 0

    if args[0] in {"start", "stop", "delete", "config", "copy", "move"}:
        return 0

    if args[0] in {"network", "profile", "project", "storage"}:
        return 0

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
