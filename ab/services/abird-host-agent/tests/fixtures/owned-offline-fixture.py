"""Focused installed-VM controls and attempt-local evidence collection."""

import errno
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import signal
import socket
import stat
import subprocess
import sys
import time


HOME = Path("/home/remote-operator")
REPO = HOME / "repo"
OUTSIDE = HOME / "owned-offline-outside"
EVIDENCE = Path("/run/owned-offline-evidence")
CAPTURE = Path("/var/lib/abird/abird-host-manager/owned-capture")
SENTINEL = b"unchanged\n"
PROBE_BYTES = b"owned offline probe\n"
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


def load(path):
    with open(path) as source:
        return json.load(source)


def save(path, value):
    temporary = str(path) + ".pending"
    with open(temporary, "x") as output:
        json.dump(value, output, sort_keys=True)
        output.flush()
        os.fsync(output.fileno())
    os.rename(temporary, path)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(*arguments):
    return subprocess.check_output(
        ["/run/current-system/sw/bin/git", "-C", str(REPO), *arguments],
        timeout=15,
    )


def listen():
    assert os.getuid() == os.geteuid() == 2700
    OUTSIDE.mkdir(mode=0o700)
    (OUTSIDE / "sentinel").write_bytes(SENTINEL)
    os.mkfifo(OUTSIDE / "fifo", 0o600)
    fifo = os.open(OUTSIDE / "fifo", os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC)
    listeners = [socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) for _ in range(2)]
    abstract = "owned-offline-vm"
    listeners[0].bind(str(OUTSIDE / "socket"))
    listeners[1].bind("\0" + abstract)
    selector = selectors.DefaultSelector()
    for index, listener in enumerate(listeners):
        listener.listen(8)
        listener.setblocking(False)
        selector.register(listener, selectors.EVENT_READ, index)
    signals = [0]
    signal.signal(signal.SIGUSR1, lambda *_: signals.__setitem__(0, signals[0] + 1))
    context = {
        "directory": str(OUTSIDE), "abstract": abstract, "pid": os.getpid(),
        "pid_namespace": os.readlink("/proc/self/ns/pid"),
        "net_namespace": os.readlink("/proc/self/ns/net"),
        "nonce": os.urandom(16).hex(), "uid": os.getuid(),
        "cgroup": Path("/proc/self/cgroup").read_text(),
    }
    assert "/abird-build.slice/" not in context["cgroup"]
    save(OUTSIDE / "ready.json", context)
    connections = [0, 0]
    controls = [0, 0]
    armed = False
    deadline = time.monotonic() + 660
    while not (OUTSIDE / "stop").exists():
        assert time.monotonic() < deadline, "offline listener deadline expired"
        for event, _ in selector.select(0.02):
            connection, _ = event.fileobj.accept()
            connections[event.data] += 1
            with connection:
                connection.settimeout(1)
                if connection.recv(1) == b"c":
                    controls[event.data] += 1
        if not armed and (OUTSIDE / "arm").exists():
            assert all(count <= 1 for count in connections) and signals[0] <= 1
            if connections == controls == [1, 1] and signals[0] == 1:
                assert (OUTSIDE / "sentinel").read_bytes() == SENTINEL
                connections = [0, 0]
                signals[0] = 0
                armed = True
                save(OUTSIDE / "armed.json", context)
    assert armed
    # Count queued connections too; stopping the observer must not hide one.
    for listener, index in zip(listeners, range(2)):
        while True:
            try:
                connection, _ = listener.accept()
            except BlockingIOError:
                break
            connections[index] += 1
            connection.close()
    # No reads of this FIFO after preflight queues q, until owned work finished.
    try:
        queued = os.read(fifo, 2)
    except BlockingIOError:
        queued = b""
    try:
        os.read(fifo, 1)
    except BlockingIOError:
        empty_after_q = True
    else:
        empty_after_q = False
    report = {
        "connections": connections, "signals": signals[0],
        "queued": queued.decode("ascii"), "empty_after_q": empty_after_q,
        "sentinel_unchanged": (OUTSIDE / "sentinel").read_bytes() == SENTINEL,
    }
    save(OUTSIDE / "final.json", report)
    for listener in listeners:
        listener.close()
    os.close(fifo)
    selector.close()


def preflight():
    assert os.getuid() == 2700
    context = load(OUTSIDE / "ready.json")
    for address in [str(OUTSIDE / "socket"), "\0" + context["abstract"]]:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.connect(address)
            client.sendall(b"c")
    (OUTSIDE / "sentinel").write_bytes(b"ordinary caller write")
    assert (OUTSIDE / "sentinel").read_bytes() == b"ordinary caller write"
    (OUTSIDE / "sentinel").write_bytes(SENTINEL)
    # Separate read-only/write-only opens: not just a self-connected RDWR FD.
    reader = os.open(OUTSIDE / "fifo", os.O_RDONLY | os.O_NONBLOCK)
    writer = os.open(OUTSIDE / "fifo", os.O_WRONLY | os.O_NONBLOCK)
    try:
        assert os.write(writer, b"p") == 1
        assert os.read(reader, 1) == b"p"
        assert os.write(writer, b"q") == 1
    finally:
        os.close(reader)
        os.close(writer)
    os.kill(context["pid"], signal.SIGUSR1)
    os.close(os.pidfd_open(context["pid"]))
    assert Path("/proc/%d/root%s/sentinel" % (context["pid"], OUTSIDE)).read_bytes() == SENTINEL
    for family, kind in [(socket.AF_INET, socket.SOCK_STREAM),
                         (socket.AF_INET6, socket.SOCK_STREAM),
                         (socket.AF_NETLINK, socket.SOCK_RAW)]:
        socket.socket(family, kind).close()
    (OUTSIDE / "arm").touch(exist_ok=False)


def configure():
    assert os.getuid() == 2700
    context = load(OUTSIDE / "armed.json")
    profile = HOME / ".gitconfig"
    (OUTSIDE / "original-gitconfig").write_bytes(profile.read_bytes())
    # Probe paths must exist at HEAD: checkout smudges before staged patch
    # application. Never commit or refresh the index after enabling callbacks.
    head = git("rev-parse", "HEAD").decode().strip()
    staged_flake = git("show", ":flake.nix")
    live_flake = (REPO / "flake.nix").read_bytes()
    assert b"owned-remote-staged" in staged_flake
    assert b"owned-remote-unstaged" in live_flake
    assert git("show", "HEAD:.gitattributes") == b"owned-offline-probe.txt filter=owned-offline\n"
    assert git("show", "HEAD:owned-offline-probe.txt") == PROBE_BYTES
    assert (REPO / "owned-offline-probe.txt").read_bytes() == PROBE_BYTES
    assert git("show", ":flake.nix") == staged_flake
    assert (REPO / "flake.nix").read_bytes() == live_flake
    save(OUTSIDE / "repository-before.json", {
        "head": head, "index": digest(REPO / ".git/index"),
        "live_flake": digest(REPO / "flake.nix"),
        "staged_flake": hashlib.sha256(staged_flake).hexdigest(),
    })
    helper = str(Path(__file__).resolve().with_name("owned-offline-helper"))
    assert helper.startswith("/nix/store/")
    arguments = json.dumps(context, sort_keys=True, separators=(",", ":"))
    for key, value in [
        ("core.fsmonitorHookVersion", "2"),
        ("filter.owned-offline.clean", "cat"),
        ("filter.owned-offline.smudge", shlex.join([helper, "smudge", arguments]) + " %f"),
        ("filter.owned-offline.required", "true"),
        ("core.fsmonitor", shlex.join([helper, "fsmonitor", arguments])),
    ]:
        git("config", "--global", key, value)


def restore():
    assert os.getuid() == 2700
    (HOME / ".gitconfig").write_bytes((OUTSIDE / "original-gitconfig").read_bytes())


def collect(attempt):
    assert os.getuid() == 0 and re.fullmatch(r"[0-9a-f]{64}", attempt)
    EVIDENCE.mkdir(mode=0o700)
    context = load(OUTSIDE / "armed.json")
    seen = set()
    records = []
    deadline = time.monotonic() + 600
    pattern = re.compile(r"owned-offline-(fsmonitor|smudge)-[0-9]+-[0-9a-f]{16}\.(proof|failure)")

    def visit(directory, relative, depth, budget):
        assert depth <= 64 and time.monotonic() < deadline
        with os.scandir(directory) as entries:
            for entry in entries:
                budget[0] += 1
                assert budget[0] <= 131072 and time.monotonic() < deadline
                if entry.is_symlink():
                    continue
                path = relative + (entry.name,)
                if entry.is_dir(follow_symlinks=False):
                    try:
                        child = os.open(entry.name, DIRECTORY_FLAGS, dir_fd=directory)
                    except FileNotFoundError:
                        continue  # Original stage may retire during observation.
                    try:
                        visit(child, path, depth + 1, budget)
                    finally:
                        os.close(child)
                elif pattern.fullmatch(entry.name) and path not in seen:
                    fd = os.open(entry.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 dir_fd=directory)
                    with os.fdopen(fd, "rb") as source:
                        metadata = os.fstat(source.fileno())
                        assert stat.S_ISREG(metadata.st_mode) and metadata.st_uid == 2700
                        assert metadata.st_nlink == 1 and metadata.st_size <= 16384
                        evidence = json.loads(source.read(16385))
                    assert len(records) < 128, "offline callback count exceeded fixture bound"
                    assert path[:2] in (("source", "source-capture"),
                                        ("source", "source-checkout")), path
                    record = {"path": "/".join(path), "evidence": evidence,
                              "failure": entry.name.endswith(".failure")}
                    if not record["failure"]:
                        assert evidence["nonce"] == context["nonce"]
                    # Archive first, then release: automatic cleanup cannot erase
                    # the only evidence. Both opens are relative to pinned dirs.
                    save(EVIDENCE / ("%03d.json" % len(records)), record)
                    records.append(record)
                    seen.add(path)
                    release = entry.name.rsplit(".", 1)[0] + ".release"
                    fd = os.open(release, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                 0o444, dir_fd=directory)
                    os.close(fd)

    # Never enumerate CAPTURE or another attempt. Open every path component
    # without following symlinks; the only recursive traversal is below this
    # recorded attempt. A vanished allocation is not evidence of success.
    parent = os.open("/", DIRECTORY_FLAGS)
    try:
        for part in CAPTURE.parts[1:]:
            child = os.open(part, DIRECTORY_FLAGS, dir_fd=parent)
            os.close(parent)
            parent = child
        while True:
            assert time.monotonic() < deadline, "offline collector deadline expired"
            try:
                directory = os.open(attempt, DIRECTORY_FLAGS, dir_fd=parent)
            except FileNotFoundError:
                pass
            else:
                try:
                    visit(directory, (), 0, [0])
                finally:
                    os.close(directory)
            if Path("/run/fleet.code").exists():
                break
            time.sleep(0.02)
    finally:
        os.close(parent)
    save(EVIDENCE / "summary.json", {"attempt": attempt, "records": records})


def verify():
    assert os.getuid() == 2700
    before = load(OUTSIDE / "repository-before.json")
    assert (HOME / ".gitconfig").read_bytes() == (OUTSIDE / "original-gitconfig").read_bytes()
    assert digest(REPO / ".git/index") == before["index"]
    assert git("rev-parse", "HEAD").decode().strip() == before["head"]
    assert digest(REPO / "flake.nix") == before["live_flake"]
    assert hashlib.sha256(git("show", ":flake.nix")).hexdigest() == before["staged_flake"]
    assert (REPO / "owned-offline-probe.txt").read_bytes() == PROBE_BYTES
    (OUTSIDE / "stop").touch(exist_ok=False)


def check():
    assert os.getuid() == 0
    assert load(OUTSIDE / "final.json") == {
        "connections": [0, 0], "signals": 0, "queued": "q",
        "empty_after_q": True, "sentinel_unchanged": True,
    }
    context = load(OUTSIDE / "armed.json")
    summary = load(EVIDENCE / "summary.json")
    records = summary["records"]
    assert records and not any(record["failure"] for record in records), records
    for record in records:
        proof = record["evidence"]
        assert proof["uid"] == proof["gid"] == 2700
        assert proof["cgroup"].startswith("0::/abird.slice/abird-build.slice/")
        assert "abird-owned-capture@" + summary["attempt"] + ".service/" in proof["cgroup"]
        assert proof["pid_namespace"] != context["pid_namespace"]
        assert proof["net_namespace"] != context["net_namespace"]
        checks = proof["checks"]
        assert checks["private_socketpair_write_shell_null"] is True
        for name in ("io_uring_setup", "pidfd_getfd", "AF_INET", "AF_INET6", "AF_NETLINK"):
            assert checks[name] == errno.EPERM, (name, checks)
        for name in ("host_signal", "host_pidfd"):
            assert checks[name] in (errno.EPERM, errno.EACCES, errno.ESRCH)
        for name in ("host_proc", "host_proc_root"):
            assert checks[name] in (errno.EPERM, errno.EACCES, errno.ENOENT, errno.EROFS)
    capture = [record["evidence"] for record in records
               if record["path"].startswith("source/source-capture/")
               and record["evidence"]["mode"] == "fsmonitor"]
    checkout = [record["evidence"] for record in records
                if record["path"].startswith("source/source-checkout/")
                and record["evidence"]["mode"] == "smudge"]
    assert capture and checkout, (
        f"missing actual callback: capture fsmonitor={len(capture)}, checkout smudge={len(checkout)}"
    )
    for proof in capture:
        outside = proof["outside"]
        assert all(value["visibility"] == "reachable" for value in outside.values()), outside
        assert outside["socket"]["connect"] in (errno.EPERM, errno.EACCES)
        assert outside["fifo"]["read"] in (errno.EPERM, errno.EACCES)
    for proof in checkout:
        for evidence in proof["outside"].values():
            assert evidence["visibility"] in ("absent", "reachable")
            if evidence["visibility"] == "absent":
                assert evidence == {"visibility": "absent", "errno": errno.ENOENT}
    visibility = {name: sorted({proof["outside"][name]["visibility"] for proof in checkout})
                  for name in ("sentinel", "socket", "fifo")}
    print(json.dumps({"capture_fsmonitor": len(capture), "checkout_smudge": len(checkout),
                      "checkout_visibility": visibility,
                      "attempt": summary["attempt"], "evidence": str(EVIDENCE)}, sort_keys=True))


if __name__ == "__main__":
    command = sys.argv[1]
    if command == "collect":
        collect(sys.argv[2])
    else:
        {"listen": listen, "preflight": preflight, "configure": configure,
         "restore": restore, "verify": verify, "check": check}[command]()
