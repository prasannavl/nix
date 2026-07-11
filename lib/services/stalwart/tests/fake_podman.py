import json
import os
import sys
from pathlib import Path


def fail(message, status=64):
    print(message, file=sys.stderr)
    sys.exit(status)


def parse_cli_args(args):
    if args[:2] == ["image", "exists"]:
        sys.exit(0)
    if args and args[0] in {"stop", "start", "rm"}:
        return [args[0]]
    if args and args[0] == "inspect":
        return ["inspect"]
    if not args or args[0] != "run":
        fail("unexpected podman args: " + " ".join(args))

    args = args[1:]
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            index += 1
            if index < len(args):
                index += 1
            break
        if arg in {"--entrypoint", "--env", "--volume", "--network", "--name", "--publish", "--user"}:
            index += 2
        elif arg in {"--interactive", "--rm", "--detach"}:
            index += 1
        elif arg.startswith("--"):
            index += 1
        else:
            index += 1
            break
    return args[index:]


def find_json_arg(cli_args):
    for index, value in enumerate(cli_args):
        if value == "--json" and index + 1 < len(cli_args):
            return cli_args[index + 1]
    return ""


def directory_rows(mode, state_dir):
    rows_by_mode = {
        "present": [{"id": "live-directory", "description": "Kanidm LDAP"}],
        "two": [
            {"id": "live-a", "description": "A"},
            {"id": "live-b", "description": "B"},
        ],
        "duplicate": [
            {"id": "live-a", "description": "A"},
            {"id": "live-a2", "description": "A"},
        ],
        "missing": [],
    }
    if mode == "create":
        return (
            [{"id": "created-directory", "description": "Missing Directory"}]
            if (state_dir / "directory-created").exists()
            else []
        )
    if mode not in rows_by_mode:
        fail(f"unknown TEST_STALWART_DIRECTORY_MODE={mode}")
    return rows_by_mode[mode]


def domain_rows(mode, state_dir):
    rows_by_mode = {
        "present": [{"id": "live-domain", "name": "abird.ai"}],
        "duplicate": [
            {"id": "live-domain", "name": "abird.ai"},
            {"id": "other-domain", "name": "abird.ai"},
        ],
        "missing": [],
    }
    if mode == "create":
        return (
            [{"id": "created-domain", "name": "abird.ai"}]
            if (state_dir / "domain-created").exists()
            else []
        )
    if mode not in rows_by_mode:
        fail(f"unknown TEST_STALWART_DOMAIN_MODE={mode}")
    return rows_by_mode[mode]


def network_listener_rows(mode):
    rows_by_mode = {
        "present": [
            {"id": "live-http", "name": "http"},
            {"id": "live-smtp", "name": "smtp"},
            {"id": "live-imaps", "name": "imaps"},
            {"id": "live-submissions", "name": "submissions"},
        ],
        "duplicate": [
            {"id": "live-http", "name": "http"},
            {"id": "other-http", "name": "http"},
        ],
        "missing": [],
    }
    if mode not in rows_by_mode:
        fail(f"unknown TEST_STALWART_NETWORK_LISTENER_MODE={mode}")
    return rows_by_mode[mode]


def print_json_lines(rows):
    for row in rows:
        print(json.dumps(row, separators=(",", ":")))


def main():
    inherited_notify = [
        name
        for name in ("NOTIFY_SOCKET", "WATCHDOG_PID", "WATCHDOG_USEC")
        if os.environ.get(name)
    ]
    if inherited_notify:
        fail("podman inherited systemd notify environment: " + ", ".join(inherited_notify), 70)

    if sys.argv[1:2] == ["run"] and "--detach" in sys.argv[1:]:
        state_dir = Path(os.environ["TEST_STALWART_STATE_DIR"])
        attempts_file = state_dir / "recovery-run-attempts"
        attempts = int(attempts_file.read_text(encoding="utf-8")) if attempts_file.exists() else 0
        attempts += 1
        attempts_file.write_text(str(attempts), encoding="utf-8")
        failures = int(os.environ.get("TEST_STALWART_RECOVERY_FAILURES", "0"))
        if attempts <= failures:
            fail("transient podman engine failure", 125)

    cli_args = parse_cli_args(sys.argv[1:])
    command = cli_args[0] if len(cli_args) > 0 else ""
    object_name = cli_args[1] if len(cli_args) > 1 else ""

    if command in {"stop", "start", "rm"}:
        return

    if command == "inspect":
        print("false")
        return

    log_file = Path(os.environ["TEST_STALWART_LOG"])
    with log_file.open("a", encoding="utf-8") as handle:
        handle.write(" ".join(cli_args) + "\n")

    state_dir = Path(os.environ["TEST_STALWART_STATE_DIR"])

    if command == "query" and object_name == "Directory":
        print_json_lines(directory_rows(os.environ.get("TEST_STALWART_DIRECTORY_MODE", "present"), state_dir))
        return

    if command == "create" and object_name == "Directory":
        (state_dir / "directory-create.json").write_text(find_json_arg(cli_args), encoding="utf-8")
        (state_dir / "directory-created").touch()
        return

    if command == "query" and object_name == "Domain":
        print_json_lines(domain_rows(os.environ.get("TEST_STALWART_DOMAIN_MODE", "present"), state_dir))
        return

    if command == "create" and object_name == "Domain":
        (state_dir / "domain-create.json").write_text(find_json_arg(cli_args), encoding="utf-8")
        (state_dir / "domain-created").touch()
        return

    if command == "query" and object_name == "NetworkListener":
        print_json_lines(network_listener_rows(os.environ.get("TEST_STALWART_NETWORK_LISTENER_MODE", "present")))


if __name__ == "__main__":
    main()
