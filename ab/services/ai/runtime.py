"""Private file primitives for inference adapters; never an inference proxy."""

import json
import os
import stat
import tempfile
from pathlib import Path


def read_credential(path):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as source:
            info = os.fstat(source.fileno())
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_uid not in (0, os.geteuid())
                or info.st_mode & 0o077
                or info.st_size > 8192
            ):
                raise ValueError
            value = source.read(8193).removesuffix(b"\n")
        if not value or len(value) > 8192 or any(byte < 33 or byte > 126 for byte in value):
            raise ValueError
        return value.decode("ascii")
    except (OSError, ValueError, TypeError):
        raise RuntimeError("inference credential unavailable or invalid") from None


def write_private_json(path, value, limit=65536):
    path = Path(path)
    payload = json.dumps(value, ensure_ascii=True, separators=(",", ":")).encode("ascii")
    if len(payload) > limit:
        raise RuntimeError("inference runtime configuration too large")
    info = path.parent.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_mode & 0o077
    ):
        raise RuntimeError("inference runtime directory must be private and owned")
    fd, temporary = tempfile.mkstemp(prefix=".inference-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
