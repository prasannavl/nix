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


def should_fail_once(args):
    prefixes = json.loads(os.environ.get("TEST_INCUS_FAIL_ONCE_PREFIXES", "[]"))
    state_file_value = os.environ.get("TEST_INCUS_FAIL_ONCE_STATE_FILE")
    if not state_file_value:
        return False

    state_file = Path(state_file_value)
    for prefix in prefixes:
        if args[: len(prefix)] == prefix and not state_file.exists():
            state_file.write_text("failed\n", encoding="utf-8")
            return True
    return False


def query_response(path):
    responses = json.loads(os.environ.get("TEST_INCUS_QUERY_RESPONSES", "{}"))
    if path in responses:
        response = responses[path]
    else:
        response = json.loads(os.environ.get("TEST_INCUS_QUERY_JSON", "{}"))
    if isinstance(response, str):
        print(response)
    else:
        print(json.dumps(response))


def stateful_command(args):
    path = Path(os.environ["TEST_INCUS_INSTANCE_FILE"])
    state = json.loads(path.read_text())
    command = args[2:] if args[:1] == ["--project"] else args
    exists = state.get("exists", True)
    if command[:1] == ["info"] and len(command) > 1:
        return 0 if exists else 1
    if command[:1] == ["query"] and "/1.0/instances/" in command[1]:
        print(json.dumps(state))
        return 0
    if command[:1] == ["create"]:
        state = {
            "exists": True,
            "metadata": {
                "status": "Stopped", "type": "container", "config": {}, "devices": {},
                "expanded_devices": {"eth0": {"type": "nic"}},
            },
        }
    elif command[:1] == ["delete"]:
        state["exists"] = False
    elif command[:1] in (["start"], ["stop"]):
        state["metadata"]["status"] = "Running" if command[0] == "start" else "Stopped"
    elif command[:1] == ["config"]:
        if command[1] == "device":
            operation, name = command[2], command[4]
            devices = state["metadata"]["devices"]
            if operation == "add":
                if name in devices:
                    print("Device already exists", file=sys.stderr)
                    return 1
                devices[name] = {"type": command[5]}
                devices[name].update(arg.split("=", 1) for arg in command[6:])
            elif operation == "override":
                inherited = state["metadata"].get("expanded_devices", {}).get(name)
                if name in devices or inherited is None:
                    print("Device is not available for override", file=sys.stderr)
                    return 1
                devices[name] = {**inherited, **dict(arg.split("=", 1) for arg in command[5:])}
            elif operation == "set":
                candidate = dict(devices[name])
                candidate.update(arg.split("=", 1) for arg in command[5:])
                if candidate["type"] == "proxy" and not all(
                    candidate.get(k) for k in ("listen", "connect")
                ):
                    print("Invalid incomplete proxy update", file=sys.stderr)
                    return 1
                devices[name] = candidate
            elif operation == "remove":
                del devices[name]
            elif operation == "unset":
                devices[name].pop(command[5], None)
        elif command[1] == "set":
            state["metadata"]["config"].update(arg.split("=", 1) for arg in command[3:])
        elif command[1] == "unset":
            state["metadata"]["config"].pop(command[3], None)
    else:
        return None
    path.write_text(json.dumps(state))
    return 0


def main():
    args = sys.argv[1:]
    write_log(args)

    command_args = args[2:] if len(args) >= 2 and args[0] == "--project" else args

    if should_fail(args):
        print(os.environ.get("TEST_INCUS_FAIL_MESSAGE", "fake incus failure"), file=sys.stderr)
        return 1

    if should_fail_once(args):
        print(os.environ.get("TEST_INCUS_FAIL_ONCE_MESSAGE", "ETag doesn't match"), file=sys.stderr)
        return 1

    if not args:
        return 0

    if os.environ.get("TEST_INCUS_INSTANCE_FILE"):
        result = stateful_command(args)
        if result is not None:
            return result

    if args[0] == "info":
        return 0

    if args[:2] in (["remote", "add"], ["remote", "switch"]):
        return 0

    if args[0] == "query":
        query_response(args[1])
        return 0

    if args[0] == "list":
        if "--all-projects" in args:
            print(os.environ.get("TEST_INCUS_LIST_ALL_JSON", "[]"))
        else:
            print(os.environ.get("TEST_INCUS_PROJECT_LIST_JSON", "[]"))
        return 0

    if command_args[:2] == ["storage", "get"] and command_args[-1:] == ["volume.size"]:
        print(os.environ.get("TEST_INCUS_STORAGE_VOLUME_SIZE", ""))
        return 0

    if args[0] in {"start", "stop", "delete", "config", "copy", "move"}:
        return 0

    if args[0] in {"network", "profile", "project", "storage"}:
        return 0

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
