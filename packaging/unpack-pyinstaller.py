#!/usr/bin/env python3
"""Unpacks a one-file PyInstaller program (spotDL) into a folder, once, at build time.

A one-file program unpacks hundreds of libraries into a new temporary folder every time it
starts, and macOS checks every one of those new files before it may run: spotDL took about
20 seconds just to start. Knob ships the unpacked folder inside the app and starts spotDL in
PyInstaller's own "already unpacked" mode (_PYI_APPLICATION_HOME_DIR), so it starts in about
a second. Writes exactly the entries the program's own start would: binaries, data, zip files
and symlinks.

Usage: unpack-pyinstaller.py PROGRAM FOLDER
"""
import os
import struct
import sys
import zlib

MAGIC = b"MEI\014\013\012\013\016"
COOKIE = struct.Struct("!8sIIii64s")
ENTRY = struct.Struct("!IIIIBc")
UNPACKED = {b"b", b"x", b"Z", b"n"}


def unpack(program: str, folder: str) -> int:
    with open(program, "rb") as handle:
        data = handle.read()
    cookie_at = data.rfind(MAGIC)
    if cookie_at < 0:
        sys.exit(f"{program} is not a one-file PyInstaller program")
    _, package_length, toc_offset, toc_length, _, _ = COOKIE.unpack_from(data, cookie_at)
    start = cookie_at + COOKIE.size - package_length
    position, end = start + toc_offset, start + toc_offset + toc_length
    root = os.path.realpath(folder)
    written = 0
    while position < end:
        length, offset, size, full_size, compressed, kind = ENTRY.unpack_from(data, position)
        name = data[position + ENTRY.size:position + length].rstrip(b"\0").decode()
        position += length
        if kind not in UNPACKED:
            continue
        target = os.path.realpath(os.path.join(root, name))
        if not target.startswith(root + os.sep):
            sys.exit(f"refusing to write outside {folder}: {name}")
        content = data[start + offset:start + offset + size]
        if compressed:
            content = zlib.decompress(content)
        if len(content) != full_size:
            sys.exit(f"{name}: expected {full_size} bytes, got {len(content)}")
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if kind == b"n":
            if os.path.lexists(target):
                os.remove(target)
            os.symlink(content.rstrip(b"\0").decode(), target)
        else:
            with open(target, "wb") as out:
                out.write(content)
            os.chmod(target, 0o755 if kind == b"b" else 0o644)
        written += 1
    return written


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[-1])
    print(f"Unpacked {unpack(sys.argv[1], sys.argv[2])} files into {sys.argv[2]}")
