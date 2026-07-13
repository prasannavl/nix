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
        if mode == "storage_container":
            if "--storage" in args:
                return
            print('Error: no container with name or ID "compose_web_1" found: no such container', file=sys.stderr)
            sys.exit(1)
        if mode == "mounted_storage_container":
            mountpoint = Path(os.environ["TEST_PODMAN_STORAGE_MOUNTPOINT"])
            if "--storage" in args:
                if any(mountpoint.iterdir()):
                    print(
                        f'Error: removing storage for container "compose_web_1": replacing mount point "{mountpoint}": directory not empty',
                        file=sys.stderr,
                    )
                    sys.exit(1)
                return
            print(
                'Error: container "compose_web_1" is mounted and cannot be removed without using force: container state improper',
                file=sys.stderr,
            )
            sys.exit(1)
        if mode == "mounted_container":
            marker = Path(os.environ["TEST_PODMAN_HISTORY_FILE"]).with_name("mounted-rm-attempted")
            if "--storage" in args or marker.exists():
                return
            marker.write_text("1\n", encoding="utf-8")
            print(
                'Error: container "compose_web_1" is mounted and cannot be removed without using force: container state improper',
                file=sys.stderr,
            )
            sys.exit(1)
        return

    if args and args[0] == "unmount":
        if mode == "mounted_storage_container":
            print('Error: no container with name or ID "compose_web_1" found: no such container', file=sys.stderr)
            sys.exit(1)
        return

    if args[:2] == ["container", "list"]:
        if "--storage" in args:
            names = os.environ.get("TEST_PODMAN_STORAGE_NAMES")
            if names is not None:
                print(names)
                return
            if mode == "storage_container":
                print("compose_web_1")
                return
        if mode == "mounted_storage_container":
            mountpoint = Path(os.environ["TEST_PODMAN_STORAGE_MOUNTPOINT"])
            if any(mountpoint.iterdir()):
                print("compose_web_1")
            return

    if args[:2] == ["container", "exists"]:
        if mode in {"container_exists", "rm_zero_leaves_exists"}:
            sys.exit(0)
        sys.exit(1)

    if args[:2] == ["image", "exists"]:
        image = args[2] if len(args) > 2 else ""
        existing_images = os.environ.get("TEST_PODMAN_EXISTING_IMAGES", "")
        if existing_images == "*" or image in existing_images.splitlines():
            sys.exit(0)
        sys.exit(1)

    if args[:2] == ["container", "cleanup"]:
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

    if args and args[0] == "load":
        print(os.environ.get("TEST_PODMAN_LOAD_OUTPUT", "Loaded image: localhost/demo/loaded:1"))
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
            after_up = os.environ.get("TEST_PODMAN_COMPOSE_PS_JSON_AFTER_UP")
            history_file = os.environ.get("TEST_PODMAN_HISTORY_FILE")
            if after_up is not None and history_file:
                history = Path(history_file).read_text(encoding="utf-8").splitlines()
                if any(line.startswith("compose ") and " up " in line for line in history):
                    print(after_up)
                    return
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
            if command == "pull" and mode == "pull_fatal_zero":
                print("Trying to pull docker.io/library/nats:2.14.0-alpine...")
                print(
                    "Error: unable to copy from source docker://nats:2.14.0-alpine: "
                    "initializing source docker://nats:2.14.0-alpine: "
                    "reading manifest 2.14.0-alpine in docker.io/library/nats: "
                    "toomanyrequests: You have reached your unauthenticated pull rate limit."
                )
                return
            if command == "pull" and mode == "pull_fatal_then_success":
                count_file = Path(os.environ["TEST_PODMAN_HISTORY_FILE"]).with_name("pull-attempt-count")
                count = int(count_file.read_text(encoding="utf-8").strip()) if count_file.exists() else 0
                count += 1
                count_file.write_text(f"{count}\n", encoding="utf-8")
                succeed_after = int(os.environ.get("TEST_PODMAN_PULL_SUCCEED_AFTER", "3"))
                if count < succeed_after:
                    print("Trying to pull docker.io/library/nats:2.14.0-alpine...")
                    print(
                        "Error: unable to copy from source docker://nats:2.14.0-alpine: "
                        "toomanyrequests: You have reached your unauthenticated pull rate limit."
                    )
                    return
            print("fake podman compose command ok")
            return

    if mode == "success":
        print("fake podman ok")
        return

    print(f"unsupported fake podman invocation for mode {mode}: {' '.join(args)}", file=sys.stderr)
    sys.exit(64)


if __name__ == "__main__":
    main()
