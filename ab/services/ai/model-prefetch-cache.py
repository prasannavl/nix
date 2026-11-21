#!/usr/bin/env python3

"""Create one pre-activation model cache without following symbolic links."""

import ctypes
import os
import pathlib
import re
import secrets
import stat
import sys


COMPONENT = re.compile(r"[A-Za-z0-9._+,:=@-]+\Z")
MAX_ID = 2_147_483_647
RENAME_NOREPLACE = 1


def fail(message):
    raise RuntimeError(message)


def parse_id(value, label):
    try:
        parsed = int(value, 10)
    except ValueError:
        fail(f"{label} is not an integer: {value}")
    if not 0 <= parsed <= MAX_ID:
        fail(f"{label} is outside the supported range: {value}")
    return parsed


def path_components(value):
    path = pathlib.PurePosixPath(value)
    components = path.parts[1:] if path.is_absolute() else ()
    if value == "/" or not components or str(path) != value:
        fail(f"cache path is not canonical: {value}")
    if any(
        component in (".", "..") or not COMPONENT.fullmatch(component)
        for component in components
    ):
        fail(f"cache path contains an unsafe component: {value}")
    return components


def rename_noreplace(source_parent_fd, source, destination_parent_fd, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = libc.renameat2
    renameat2.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    renameat2.restype = ctypes.c_int
    result = renameat2(
        source_parent_fd,
        os.fsencode(source),
        destination_parent_fd,
        os.fsencode(destination),
        RENAME_NOREPLACE,
    )
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)


def open_directory(parent_fd, name, writable=False):
    access = os.O_RDONLY if writable else os.O_PATH
    return os.open(
        name,
        access | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=parent_fd,
    )


def create_directory(parent_fd, name, mode, owner=None):
    for _attempt in range(16):
        staging = f".ai-model-prefetch-{os.getpid()}-{secrets.token_hex(12)}"
        entry = "entry"
        try:
            os.mkdir(staging, 0o700, dir_fd=parent_fd)
        except FileExistsError:
            continue

        staging_fd = None
        temporary_fd = None
        keep_fd = False
        published = False
        try:
            staging_fd = open_directory(parent_fd, staging, writable=True)
            staging_stat = os.fstat(staging_fd)
            if (
                staging_stat.st_uid != os.geteuid()
                or stat.S_IMODE(staging_stat.st_mode) != 0o700
            ):
                fail("temporary cache staging identity changed during creation")
            os.mkdir(entry, 0o700, dir_fd=staging_fd)
            temporary_fd = open_directory(staging_fd, entry, writable=True)
            temporary_stat = os.fstat(temporary_fd)
            if (
                temporary_stat.st_uid != os.geteuid()
                or stat.S_IMODE(temporary_stat.st_mode) != 0o700
            ):
                fail("temporary cache directory identity changed during creation")
            if owner is not None and (
                temporary_stat.st_uid != owner[0]
                or temporary_stat.st_gid != owner[1]
            ):
                os.fchown(temporary_fd, owner[0], owner[1])
            os.fchmod(temporary_fd, mode)
            prepared_stat = os.fstat(temporary_fd)
            if owner is not None and (
                prepared_stat.st_uid != owner[0]
                or prepared_stat.st_gid != owner[1]
            ):
                fail("temporary cache directory ownership changed before publication")
            if stat.S_IMODE(prepared_stat.st_mode) != mode:
                fail("temporary cache directory mode changed before publication")
            try:
                rename_noreplace(staging_fd, entry, parent_fd, name)
                published = True
            except FileExistsError:
                return open_directory(parent_fd, name), False
            keep_fd = True
            return temporary_fd, True
        finally:
            if temporary_fd is not None and not keep_fd:
                os.close(temporary_fd)
            if staging_fd is not None:
                if not published:
                    try:
                        os.rmdir(entry, dir_fd=staging_fd)
                    except FileNotFoundError:
                        pass
                os.close(staging_fd)
            try:
                os.rmdir(staging, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
    fail("could not allocate a temporary cache directory")


def open_or_create(parent_fd, name, mode, owner=None):
    try:
        return open_directory(parent_fd, name), False
    except FileNotFoundError:
        return create_directory(parent_fd, name, mode, owner)


def verify_reachable(components, expected):
    current_fd = os.open("/", os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for component in components:
            next_fd = open_directory(current_fd, component)
            os.close(current_fd)
            current_fd = next_fd
        actual = os.fstat(current_fd)
        if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
            fail("cache path changed while it was being prepared")
    finally:
        os.close(current_fd)


def prepare(path, uid, gid):
    components = path_components(path)
    current_fd = os.open("/", os.O_PATH | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for index, component in enumerate(components):
            is_leaf = index == len(components) - 1
            next_fd, _created = open_or_create(
                current_fd,
                component,
                0o750 if is_leaf else 0o755,
                (uid, gid) if is_leaf else None,
            )
            os.close(current_fd)
            current_fd = next_fd
            if is_leaf:
                leaf = os.fstat(current_fd)
                if (leaf.st_uid, leaf.st_gid) != (uid, gid):
                    fail(
                        f"cache ownership conflict at {path}: expected {uid}:{gid}, "
                        f"found {leaf.st_uid}:{leaf.st_gid}"
                    )
                mode = stat.S_IMODE(leaf.st_mode)
                if mode != 0o750:
                    fail(f"cache mode conflict at {path}: expected 0750, found {mode:04o}")
                verify_reachable(components, leaf)
    finally:
        if current_fd is not None:
            os.close(current_fd)


def main(argv):
    if len(argv) != 4:
        fail("usage: model-prefetch-cache.py CACHE_DIR UID GID")
    os.umask(0)
    prepare(argv[1], parse_id(argv[2], "UID"), parse_id(argv[3], "GID"))


if __name__ == "__main__":
    try:
        main(sys.argv)
    except (OSError, RuntimeError) as error:
        print(f"ai-model-prefetch-cache: {error}", file=sys.stderr)
        raise SystemExit(1) from error
