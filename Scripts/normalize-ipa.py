#!/usr/bin/env python3
"""Rewrite an IPA with a plain zip writer so every entry is laid out the classic way.

Why this exists: after ipapatch rewrites parts of the archive, some entries come back
written in "streaming" form - the local header carries zero sizes and the real CRC /
sizes sit in a data descriptor after the data (general purpose bit 3). Desktop
extractors and python's zipfile read those fine (the central directory is correct),
but a number of iOS signing tools walk the local headers and then just refuse the
archive with a plain "cannot open zip" - no diagnostic. Rewriting every entry with
its sizes and CRC in the local header removes that class of failure entirely.

Preserved: entry order, names, timestamps, unix permission bits, directory entries.
Changed: files are re-deflated (level 6), directory entries stay stored, and no entry
uses a data descriptor afterwards.

Usage:
    normalize-ipa.py <file.ipa> [<file.ipa> ...]

The rewrite is done in place through a temporary file next to the result, so an
interrupted run cannot leave a half-written IPA behind.
"""

import hashlib
import os
import sys
import tempfile
import time
import zipfile

COMPRESS_LEVEL = 6


def descriptors(infos):
    return sum(1 for i in infos if i.flag_bits & 0x8)


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def normalize(path):
    if not os.path.isfile(path):
        raise SystemExit("error: not a file: " + path)

    before_size = os.path.getsize(path)
    started = time.time()

    with zipfile.ZipFile(path) as source:
        infos = source.infolist()
        before_descriptors = descriptors(infos)
        if before_descriptors == 0:
            print("  %s: already standard (%d entries, %d bytes)"
                  % (path, len(infos), before_size))
            return

        handle, temp_path = tempfile.mkstemp(prefix=".normalize-", suffix=".ipa",
                                             dir=os.path.dirname(os.path.abspath(path)))
        os.close(handle)
        try:
            with zipfile.ZipFile(temp_path, "w", compression=zipfile.ZIP_DEFLATED,
                                 compresslevel=COMPRESS_LEVEL, allowZip64=True) as target:
                for info in infos:
                    entry = zipfile.ZipInfo(info.filename, date_time=info.date_time)
                    entry.external_attr = info.external_attr
                    entry.create_system = info.create_system
                    if info.is_dir():
                        entry.compress_type = zipfile.ZIP_STORED
                        target.writestr(entry, b"")
                    else:
                        entry.compress_type = zipfile.ZIP_DEFLATED
                        target.writestr(entry, source.read(info.filename))
        except BaseException:
            if os.path.exists(temp_path):
                os.unlink(temp_path)
            raise

    # Source is closed by now: Windows refuses to replace a file that is still open.
    try:
        os.replace(temp_path, path)
    except BaseException:
        if os.path.exists(temp_path):
            os.unlink(temp_path)
        raise

    after_size = os.path.getsize(path)
    print("  %s: %d entry/entries rewritten (%d -> %d bytes, %.1fs)"
          % (path, len(infos), before_size, after_size, time.time() - started))
    print("     streaming entries removed: %d" % before_descriptors)
    print("     sha256: %s" % sha256_of(path))


def main(argv):
    if len(argv) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    for path in argv[1:]:
        normalize(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
