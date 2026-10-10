"""Shared installation primitives. No device commands or service side effects."""
import os
from pathlib import Path
import shutil
import tempfile
import fcntl
from contextlib import contextmanager

LOCK_VARIABLE = "ENVIOUSCOOLER_MANAGEMENT_LOCK_FD"


@contextmanager
def management_lock():
    path = Path(tempfile.gettempdir()) / f"enviouscooler-management-{os.getuid()}.lock"
    inherited = os.environ.get(LOCK_VARIABLE)
    if inherited is not None:
        descriptor = int(inherited)
        actual, expected = os.fstat(descriptor), path.stat()
        if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
            raise RuntimeError("Invalid inherited management lock.")
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield descriptor
        return
    descriptor = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another installation or service change is in progress.")
        yield descriptor
    finally:
        os.close(descriptor)


def atomic_copy(source, destination):
    destination = Path(destination)
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".razer-new-", delete=False) as file:
        temporary = Path(file.name)
    try:
        shutil.copy2(source, temporary)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def atomic_bytes(data, destination):
    destination = Path(destination)
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".razer-new-", delete=False) as file:
        temporary = Path(file.name)
        file.write(data)
        file.flush()
        os.fsync(file.fileno())
    try:
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
