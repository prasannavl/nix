import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def record_args(args):
    Path(os.environ["TEST_PODMAN_ARGS_FILE"]).write_text(" ".join(args) + "\n", encoding="utf-8")
    history_file = os.environ.get("TEST_PODMAN_HISTORY_FILE")
    if history_file:
        with Path(history_file).open("a", encoding="utf-8") as handle:
            handle.write(" ".join(args) + "\n")


def assert_no_systemd_notify_env():
    inherited = [name for name in ("NOTIFY_SOCKET", "WATCHDOG_PID", "WATCHDOG_USEC") if os.environ.get(name)]
    if inherited:
        print("podman inherited systemd notify environment: " + ", ".join(inherited), file=sys.stderr)
        sys.exit(70)


def spawn_term_resistant_child():
    child_pid_file = os.environ["TEST_PODMAN_CHILD_PID_FILE"]
    subprocess.Popen(
        [
            "bash",
            "-c",
            "trap '' TERM; "
            "printf '%s\\n' $$ > \"$TEST_PODMAN_CHILD_PID_FILE\"; "
            "while :; do sleep 1; done",
        ],
        env={**os.environ, "TEST_PODMAN_CHILD_PID_FILE": child_pid_file},
    )


def block_until_supervisor_kills_us():
    signal.signal(signal.SIGTERM, lambda _signum, _frame: sys.exit(143))
    time.sleep(30)
    print(f"TEST_PODMAN_MODE={os.environ.get('TEST_PODMAN_MODE', 'success')} was not interrupted", file=sys.stderr)
    sys.exit(65)


def main():
    assert_no_systemd_notify_env()
    args = sys.argv[1:]
    record_args(args)

    mode = os.environ.get("TEST_PODMAN_MODE", "success")

    if args and args[0] == "ps":
        if "--format" in args and "json" in args:
            print(os.environ.get("TEST_PODMAN_PS_JSON", "[]"))
            return
        if "--format" in args and "{{.ID}}" in args:
            ids = os.environ.get("TEST_PODMAN_PS_IDS", "")
            if ids:
                print(ids)
            return
        if "-q" in args:
            ids = os.environ.get("TEST_PODMAN_PS_IDS", "")
            if ids:
                print(ids)
            return
        print(os.environ.get("TEST_PODMAN_PS_OUTPUT", ""))
        return

    if args and args[0] == "rm":
        return

    if args and args[0] == "update":
        return

    if args and args[0] == "inspect":
        if "--format" in args and "{{json .Mounts}}" in args:
            print(os.environ.get("TEST_PODMAN_INSPECT_MOUNTS_JSON", "[]"))
            return
        if "--format" in args and "{{json .State}}" in args:
            print(os.environ.get("TEST_PODMAN_INSPECT_STATE_JSON", '{"Running":true,"Pid":1,"ConmonPid":1}'))
            return
        print(os.environ.get("TEST_PODMAN_INSPECT_JSON", "{}"))
        return

    if args and args[0] == "volume":
        if len(args) > 1 and args[1] == "rm":
            return

    if args and args[0] == "compose":
        if "up" in args:
            if mode == "success":
                print("fake podman compose up ok")
                return
            if mode == "fatal":
                print('Error: container name "stale" is already in use', flush=True)
                time.sleep(30)
            if mode == "fatal_child":
                print('Error: container name "stale" is already in use', flush=True)
                spawn_term_resistant_child()
                block_until_supervisor_kills_us()
            if mode == "timeout":
                time.sleep(30)
            if mode == "timeout_child":
                spawn_term_resistant_child()
                block_until_supervisor_kills_us()
            print(f"unknown TEST_PODMAN_MODE={mode}", file=sys.stderr)
            sys.exit(64)
        if "ps" in args:
            print(os.environ.get("TEST_PODMAN_COMPOSE_PS_JSON", '[{"State":"running","Labels":{"io.podman.compose.service":"web"}}]'))
            return
        if "kill" in args:
            print("fake podman compose kill ok")
            return
        for command in ("down", "stop", "pull"):
            if command not in args:
                continue
            if mode == f"{command}_timeout_child":
                spawn_term_resistant_child()
                block_until_supervisor_kills_us()
            print("fake podman compose command ok")
            return

    if mode == "success":
        print("fake podman ok")
        return

    print(f"unsupported fake podman invocation for mode {mode}: {' '.join(args)}", file=sys.stderr)
    sys.exit(64)


if __name__ == "__main__":
    main()
