"""VM-only Git callbacks. Success evidence is published only after every probe."""

import ctypes
import errno
import json
import os
import signal
import socket
import stat
import subprocess
import sys
import time
import traceback


PROBE_BYTES = b"owned offline probe\n"
DENIED = (errno.EPERM, errno.EACCES)


def denied(call, errors=DENIED):
    try:
        result = call()
    except OSError as error:
        assert error.errno in errors, (error.errno, errors, str(error))
        return error.errno
    else:
        if isinstance(result, int):
            os.close(result)
        elif isinstance(result, socket.socket):
            result.close()
        raise AssertionError("external operation succeeded")


def publish(path, value):
    temporary = path + ".pending"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as output:
        json.dump(value, output, sort_keys=True)
        output.flush()
        os.fsync(output.fileno())
    os.rename(temporary, path)


def probe(mode, context):
    assert mode in ("fsmonitor", "smudge"), mode
    assert os.getuid() == os.geteuid() == 2700
    if mode == "fsmonitor":
        assert sys.argv[3] == "2", sys.argv[3:]
        payload = b"owned-offline-vm\0/\0"
    else:
        assert sys.argv[3:] == ["owned-offline-probe.txt"], sys.argv[3:]
        payload = sys.stdin.buffer.read(4097)
        assert payload == PROBE_BYTES, payload

    with open("/proc/self/cgroup") as source:
        cgroup = source.read(4097)
    assert cgroup.startswith("0::/abird.slice/abird-build.slice/"), cgroup
    pid_namespace = os.readlink("/proc/self/ns/pid")
    net_namespace = os.readlink("/proc/self/ns/net")
    assert pid_namespace != context["pid_namespace"]
    assert net_namespace != context["net_namespace"]
    assert os.readlink("/proc/self") == str(os.getpid())

    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    assert libc.syscall(444, 0, 0, 1) >= 9  # No degraded/skip profile.
    checks = {}
    ctypes.set_errno(0)
    assert libc.syscall(425, 1, 0) == -1  # io_uring_setup
    assert ctypes.get_errno() == errno.EPERM
    checks["io_uring_setup"] = errno.EPERM
    # Valid private descriptors, not EBADF from an invalid pidfd. Outside task
    # pidfds are separately unreachable in the fresh PID namespace below.
    pidfd = os.pidfd_open(os.getpid())
    try:
        with open("/dev/null", "rb") as target:
            ctypes.set_errno(0)
            assert libc.syscall(438, pidfd, target.fileno(), 0) == -1
            assert ctypes.get_errno() == errno.EPERM
            checks["pidfd_getfd"] = errno.EPERM
    finally:
        os.close(pidfd)
    for family, kind in [
        (socket.AF_INET, socket.SOCK_STREAM),
        (socket.AF_INET6, socket.SOCK_STREAM),
        (socket.AF_NETLINK, socket.SOCK_RAW),
    ]:
        checks[family.name] = denied(
            lambda: socket.socket(family, kind), (errno.EPERM,)
        )

    # A missing path in the sealed checkout is isolation, NOT a pathname-policy
    # denial. The collector separately requires reachable capture socket/FIFO
    # denials, with successful ordinary same-UID controls before admission.
    outside = {}
    for name, kind in [("sentinel", stat.S_ISREG), ("socket", stat.S_ISSOCK),
                       ("fifo", stat.S_ISFIFO)]:
        path = context["directory"] + "/" + name
        try:
            metadata = os.stat(path, follow_symlinks=False)
        except FileNotFoundError:
            outside[name] = {"visibility": "absent", "errno": errno.ENOENT}
            continue
        assert kind(metadata.st_mode), (name, metadata.st_mode)
        evidence = {"visibility": "reachable"}
        if name == "socket":
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                evidence["connect"] = denied(lambda: client.connect(path))
        elif name == "fifo":
            evidence["read"] = denied(
                lambda: os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            )
            evidence["write"] = denied(
                lambda: os.open(path, os.O_WRONLY | os.O_NONBLOCK),
                DENIED + (errno.EROFS,),
            )
        else:
            evidence["write"] = denied(
                lambda: os.open(path, os.O_WRONLY | os.O_TRUNC),
                DENIED + (errno.EROFS,),
            )
        outside[name] = evidence
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        checks["abstract_connect"] = denied(
            lambda: client.connect("\0" + context["abstract"]),
            DENIED + (errno.ECONNREFUSED,),
        )
    checks["host_pidfd"] = denied(
        lambda: os.pidfd_open(context["pid"]), DENIED + (errno.ESRCH,)
    )
    checks["host_signal"] = denied(
        lambda: os.kill(context["pid"], signal.SIGUSR1),
        DENIED + (errno.ESRCH,),
    )
    checks["host_proc"] = denied(
        lambda: os.stat("/proc/" + str(context["pid"])),
        DENIED + (errno.ENOENT,),
    )
    checks["host_proc_root"] = denied(
        lambda: os.open(
            "/proc/%d/root%s/sentinel" % (context["pid"], context["directory"]),
            os.O_WRONLY,
        ),
        DENIED + (errno.ENOENT, errno.EROFS),
    )

    left, right = socket.socketpair()
    with left, right:
        left.sendall(b"private")
        assert right.recv(7) == b"private"
    private = "/tmp/owned-offline-private-%d" % os.getpid()
    with open(private, "xb") as output:
        output.write(b"private")
    with open(private, "rb") as source:
        assert source.read() == b"private"
    os.unlink(private)
    subprocess.run(
        ["/bin/sh", "-c", "printf sink > /dev/null"],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        check=True, timeout=5,
    )
    checks["private_socketpair_write_shell_null"] = True
    return payload, {
        "version": 1, "mode": mode, "nonce": context["nonce"],
        "uid": os.getuid(), "gid": os.getgid(), "pid": os.getpid(),
        "cgroup": cgroup, "pid_namespace": pid_namespace,
        "net_namespace": net_namespace, "outside": outside, "checks": checks,
    }


def await_release(name):
    deadline = time.monotonic() + 60
    while not os.path.exists(name + ".release"):
        assert time.monotonic() < deadline, "fixture evidence collector timed out"
        time.sleep(0.02)


def main():
    mode, context = sys.argv[1], json.loads(sys.argv[2])
    name = "/tmp/owned-offline-%s-%d-%s" % (mode, os.getpid(), os.urandom(8).hex())
    try:
        payload, evidence = probe(mode, context)
        publish(name + ".proof", evidence)
        await_release(name)
        sys.stdout.buffer.write(payload)
        sys.stdout.buffer.flush()
    except Exception:
        # Git may swallow fsmonitor failure. A failure marker is never a proof;
        # the collector rejects it even if another callback already succeeded.
        publish(name + ".failure", {"mode": mode, "error": traceback.format_exc()})
        await_release(name)
        raise


if __name__ == "__main__":
    main()
